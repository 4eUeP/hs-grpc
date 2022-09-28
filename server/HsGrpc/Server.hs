{-# LANGUAGE DataKinds    #-}
{-# LANGUAGE GADTs        #-}
{-# LANGUAGE TypeFamilies #-}

module HsGrpc.Server
  ( GRPC (..)
  , ServerOptions (..)
  , runServer

    -- * Handlers
  , UnaryHandler
  , BiDiStreamHandler
  , ServiceHandler
  , unary
  , bidiStream
    -- **
  , BiDiStream
  , streamRead
  , streamWrite

    -- * Helpers
  , whileM
  , bs2str

    -- * Internals
  , AsioServer
  , newAsioServer
  , runAsioGrpc
  ) where

import           Control.Concurrent            (forkIO)
import qualified Control.Concurrent.Async      as Async
import qualified Control.Exception             as Ex
import           Control.Monad                 (unless, void, when)
import           Data.ByteString               (ByteString)
import qualified Data.ByteString.Char8         as BSC
import           Data.ByteString.Short         (ShortByteString)
import           Data.Kind                     (Type)
import           Data.ProtoLens.Service.Types  (HasMethod, MethodName,
                                                Service (..))
import           Data.Proxy                    (Proxy (..))
import qualified Data.Text                     as Text
import qualified Data.Text.Encoding            as Text
import           Data.Word                     (Word8)
import           Foreign.ForeignPtr            (ForeignPtr, newForeignPtr,
                                                withForeignPtr)
import           Foreign.Ptr                   (Ptr, nullPtr)
import           Foreign.Storable              (peek, poke)
import           GHC.TypeLits                  (Symbol, symbolVal)
import qualified HsForeign                     as HF
import qualified System.IO                     as IO

import           HsGrpc.Common.Foreign.Channel
import           HsGrpc.Common.Utils
import           HsGrpc.Server.FFI
import           HsGrpc.Server.Message         (Message, decodeMessage,
                                                encodeMessage)
import           HsGrpc.Server.Types

-------------------------------------------------------------------------------

data GRPC (s :: Type) (m :: Symbol) = GRPC

type GrpcMethod = ByteString

getGrpcMethod :: (HasMethod s m) => GRPC s m -> GrpcMethod
getGrpcMethod rpc =
  "/" <> srvPkg rpc Proxy <> "." <> srvName rpc Proxy <> "/"
      <> method rpc Proxy
  where
    srvPkg :: (Service s) => GRPC s m -> Proxy (ServicePackage s) -> GrpcMethod
    srvPkg _ p = BSC.pack $ symbolVal p

    srvName :: (Service s) => GRPC s m -> Proxy (ServiceName s) -> GrpcMethod
    srvName _ p = BSC.pack $ symbolVal p

    method :: (HasMethod s m) => GRPC s m -> Proxy (MethodName s m) -> GrpcMethod
    method _ p = BSC.pack $ symbolVal p
{-# INLINE getGrpcMethod #-}

runServer :: ServerOptions -> [ServiceHandler] -> IO ()
runServer ServerOptions{..} handlers = do
  server <- newAsioServer serverHost serverPort serverSslOptions serverParallelism
  runAsioGrpc server handlers serverOnStarted

-------------------------------------------------------------------------------

type AsioServer = ForeignPtr CppAsioServer

newAsioServer
  :: ShortByteString -> Int
  -> Maybe SslServerCredentialsOptions
  -> Int
  -> IO AsioServer
newAsioServer host port m_sslOpts parallelism = do
  ptr <-
    HF.withShortByteString host $ \host' host_len ->
    HF.withMaybePtr m_sslOpts withSslServerCredentialsOptions $ \sslOpts' ->
      new_asio_server host' host_len port sslOpts' parallelism
  if ptr == nullPtr then Ex.throwIO $ ServerException "newGrpcServer failed!"
                    else newForeignPtr delete_asio_server_fun ptr

runAsioGrpc :: AsioServer -> [ServiceHandler] -> Maybe (IO ()) -> IO ()
runAsioGrpc server handlers onStarted =
  withForeignPtr server $ \server_ptr ->
  HF.withByteStringList (map rpcMethod handlers) $ \ms' ms_len' total_len ->
  HF.withPrimList (map (handlerCStreamingType . rpcHandler) handlers) $ \mt' _mt_len ->
  withProcessorCallback (processorCallback $ map rpcHandler handlers) $ \cbPtr -> do
    evm <- getSystemEventManager' $ ServerException "failed to get event manager"
    withFdEventNotification evm onStarted OneShot $ \(Fd cfdOnStarted) -> do
      let start = run_asio_server server_ptr ms' ms_len' mt' total_len cbPtr cfdOnStarted
          stop a = shutdown_asio_server server_ptr >> Async.wait a
       in Ex.bracket (Async.async start) stop Async.wait

-------------------------------------------------------------------------------
-- Handlers

type UnaryHandler i o = ServerContext -> i -> IO o
type BiDiStreamHandler i o a = ServerContext -> BiDiStream i o -> IO a

data BiDiStream i o = BiDiStream
  { bidiReadChannel  :: {-# UNPACK #-}!(Ptr CppChannelIn)
  , bidiWriteChannel :: {-# UNPACK #-}!(Ptr CppChannelOut)
  }

streamRead :: Message i => BiDiStream i o -> IO (Maybe i)
streamRead stream = do
  m_bs <- readCppChannel $ bidiReadChannel stream
  case m_bs of
    Nothing -> return Nothing
    Just req ->
      case decodeMessage req of
        -- FIXME: Choose another specific exception?
        Left errmsg -> Ex.throwIO $ ServerException (Text.pack errmsg)
        Right msg   -> return (Just msg)

streamWrite :: Message o => BiDiStream i o -> Maybe o -> IO ()
streamWrite stream Nothing = closeOutChannel $ bidiWriteChannel stream
streamWrite stream (Just msg) = do
  ret <- writeCppChannel (bidiWriteChannel stream) $ encodeMessage msg
  -- FIXME: Choose another specific exception?
  unless (ret == 0) $ Ex.throwIO $ ServerException "writeCppChannel failed"

data RpcHandler where
  UnaryHandler
    :: (Message i, Message o) => UnaryHandler i o -> RpcHandler
  BiDiStreamHandler
    :: (Message i, Message o) => BiDiStreamHandler i o a -> RpcHandler

instance Show RpcHandler where
  show (UnaryHandler _)      = "<UnaryHandler>"
  show (BiDiStreamHandler _) = "<BiDiStreamHandler>"

handlerCStreamingType :: RpcHandler -> Word8
handlerCStreamingType (UnaryHandler _)      = C_StreamingType_NonStreaming
handlerCStreamingType (BiDiStreamHandler _) = C_StreamingType_BiDiStreaming

data ServiceHandler = ServiceHandler
  { rpcMethod  :: !GrpcMethod
  , rpcHandler :: !RpcHandler
  } deriving (Show)

unary
  :: (HasMethod s m, Message i, Message o)
  => GRPC s m
  -> UnaryHandler i o
  -> ServiceHandler
unary grpc handler =
  ServiceHandler{ rpcMethod = getGrpcMethod grpc
                , rpcHandler = UnaryHandler handler
                }

bidiStream
  :: (HasMethod s m, Message i, Message o)
  => GRPC s m
  -> BiDiStreamHandler i o a
  -> ServiceHandler
bidiStream grpc handler =
  ServiceHandler{ rpcMethod = getGrpcMethod grpc
                , rpcHandler = BiDiStreamHandler handler
                }

-------------------------------------------------------------------------------

processorCallback :: [RpcHandler] -> ProcessorCallback
processorCallback handlers request_ptr response_ptr = do
  req <- peek request_ptr
  -- the cpp side already makes the bound check
  let handler = handlers !! requestHandlerIdx req   -- TODO: use vector to gain O(1) access
  case handler of
    UnaryHandler hd -> unaryCallback req hd response_ptr
    BiDiStreamHandler hd -> void $ forkIO $ bidiStreamCallback req hd response_ptr

unaryCallback
  :: (Message i, Message o)
  => Request -> UnaryHandler i o -> Ptr Response -> IO ()
unaryCallback Request{..} hd response_ptr = catchGrpcError response_ptr $ do
  let e_requestMsg = decodeMessage requestPayload
  case e_requestMsg of
    Left errmsg -> parsingReqErrReply response_ptr (BSC.pack errmsg)
    Right requestMsg -> do
      replyBs <- encodeMessage <$> hd requestServerContext requestMsg
      poke response_ptr defResponse{responseData = Just replyBs}
{-# INLINABLE unaryCallback #-}

-- TODO: before we close all channels, we should wait WriteChannel to flush all.
bidiStreamCallback
  :: Request
  -> BiDiStreamHandler i o a
  -> Ptr Response
  -> IO ()
bidiStreamCallback req hd response_ptr =
  let stream = BiDiStream (requestReadChannel req) (requestWriteChannel req)
      action = void $ hd (requestServerContext req) stream
      clean = do
        closeOutChannel $ bidiWriteChannel stream
        closeInChannel $ bidiReadChannel stream
   in void $ catchGrpcError' response_ptr clean action

-------------------------------------------------------------------------------

catchGrpcError :: Ptr Response -> IO () -> IO ()
catchGrpcError ptr = void . catchGrpcError' ptr (pure ())

catchGrpcError' :: Ptr Response -> IO b -> IO a -> IO (Maybe a)
catchGrpcError' ptr sequel action =
  let handlers =
        [ Ex.Handler $ \(GrpcError status) -> do
            errReply ptr status
            _ <- sequel
            pure Nothing
          -- NOTE: SomeException should be the last Handler
        , Ex.Handler $ \(ex :: Ex.SomeException) -> do
            someExReply ptr ex
            _ <- sequel
            pure Nothing
        ]
   in do a <- (Just <$> action) `Ex.catches` handlers
         maybe (pure Nothing) (\x -> do _ <- sequel; pure $ Just x) a

errReply :: Ptr Response -> GrpcStatus -> IO ()
errReply ptr GrpcStatus{..} =
  poke ptr Response{ responseData = Nothing
                   , responseStatusCode = statusCode
                   , responseErrorMsg = statusErrorMsg
                   , responseErrorDetails = statusErrorDetails
                   }

someExReply :: Ptr Response -> Ex.SomeException -> IO ()
someExReply ptr ex = do
  IO.hPutStrLn IO.stderr $ x ++ show ex
  errReply ptr $ GrpcStatus StatusInternal (Just . BSC.pack . show $ ex) Nothing
  where
    x :: String
    x = "HsGrpc.Server: unexpected SomeException: "

parsingReqErrReply :: Ptr Response -> ByteString -> IO ()
parsingReqErrReply ptr errmsg = poke ptr $
  Response{ responseData = Nothing
          , responseStatusCode = StatusInternal
          , responseErrorMsg = Just errmsg
          , responseErrorDetails = Nothing
          }

-------------------------------------------------------------------------------

whileM :: Monad m => m Bool -> m ()
whileM act = do
  b <- act
  when b $ whileM act
{-# INLINE whileM #-}

bs2str :: ByteString -> String
bs2str = Text.unpack . Text.decodeUtf8
{-# INLINE bs2str #-}
