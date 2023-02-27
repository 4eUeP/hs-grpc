{-# LANGUAGE BangPatterns           #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE TypeFamilies           #-}

module HsGrpc.Server
  ( GRPC (..)
  , ServerOptions (..)
  , runServer

    -- * Handlers
  , UnaryHandler
  , ClientStreamHandler
  , ServerStreamHandler
  , BidiStreamHandler
  , ServiceHandler
  , unary
  , clientStream
  , serverStream
  , bidiStream
  , handlerUseThreadPool
    -- **
  , InStream
  , OutStream
  , BidiStream
  , StreamInput, streamRead
  , StreamOutput, streamWrite

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
import           Data.Maybe                    (fromMaybe)
import           Data.ProtoLens.Service.Types  (HasMethod, MethodName,
                                                Service (..))
import           Data.Proxy                    (Proxy (..))
import qualified Data.Text                     as Text
import qualified Data.Text.Encoding            as Text
import           Data.Word                     (Word8)
import           Foreign.ForeignPtr            (ForeignPtr, newForeignPtr,
                                                withForeignPtr)
import           Foreign.Marshal.Utils         (fromBool)
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
  server <- newAsioServer
              serverHost serverPort serverParallelism
              serverSslOptions serverInterceptors
  runAsioGrpc server handlers serverOnStarted

-------------------------------------------------------------------------------

type AsioServer = ForeignPtr CppAsioServer

newAsioServer
  :: ShortByteString
  -> Int    -- ^ port
  -> Int    -- ^ parallelism
  -> Maybe SslServerCredentialsOptions
  -> [ServerInterceptor]
  -> IO AsioServer
newAsioServer host port parallelism m_sslOpts interceptors = do
  ptr <-
    HF.withShortByteString host $ \host' host_len ->
    HF.withMaybePtr m_sslOpts withSslServerCredentialsOptions $ \sslOpts' ->
    HF.withPrimList (map toCItcptFact interceptors) $ \intcept' intcept_size ->
      new_asio_server host' host_len port parallelism sslOpts' intcept' intcept_size
  if ptr == nullPtr then Ex.throwIO $ ServerException "newGrpcServer failed!"
                    else newForeignPtr delete_asio_server_fun ptr
  where
    toCItcptFact :: ServerInterceptor -> Ptr CServerInterceptorFactory
    toCItcptFact (ServerInterceptorFromPtr ptr) = ptr
    toCItcptFact (ServerInterceptor _) = error "TODO: NotImplemented"

runAsioGrpc :: AsioServer -> [ServiceHandler] -> Maybe (IO ()) -> IO ()
runAsioGrpc server handlers onStarted =
  withForeignPtr server $ \server_ptr ->
  -- handlers info
  HF.withByteStringList (map rpcMethod handlers) $ \ms' ms_len' total_len ->
  HF.withPrimList (map (handlerCStreamingType . rpcHandler) handlers) $ \mt' _mt_len ->
  HF.withPrimList (map (fromBool . rpcUseThreadPool) handlers) $ \mUseThread' _ ->
  -- handlers callback
  withProcessorCallback (processorCallback $ map rpcHandler handlers) $ \cbPtr -> do
    evm <- getSystemEventManager' $ ServerException "failed to get event manager"
    withFdEventNotification evm onStarted OneShot $ \(Fd cfdOnStarted) -> do
      let start = run_asio_server server_ptr
                                  ms' ms_len' mt' mUseThread' total_len
                                  cbPtr
                                  cfdOnStarted
          stop a = shutdown_asio_server server_ptr >> Async.wait a
       in Ex.bracket (Async.async start) stop Async.wait

-------------------------------------------------------------------------------
-- Handlers

newtype InStream i = InStream ChannelIn
newtype OutStream o = OutStream ChannelOut
newtype BidiStream i o = BidiStream (InStream i, OutStream o)

class Message i => StreamInput i s | s -> i where
  streamRead :: s -> IO (Maybe i)

instance Message i => StreamInput i (BidiStream i o) where
  streamRead (BidiStream (i, _)) = streamRead i
  {-# INLINE streamRead #-}

instance Message i => StreamInput i (InStream i) where
  streamRead (InStream s) = do
    m_bs <- readChannel s
    case m_bs of
      Nothing -> return Nothing
      Just req ->
        case decodeMessage req of
          Left errmsg ->
            let x = "streamRead decoding request failed: " <> BSC.pack errmsg
             in throwGrpcError $ GrpcStatus StatusInternal (Just x) Nothing
          Right msg -> return (Just msg)
  {-# INLINE streamRead #-}

class Message o => StreamOutput o s | s -> o where
  streamWrite :: s -> Maybe o -> IO (Either String ())

instance Message o => StreamOutput o (OutStream o) where
  streamWrite (OutStream s) Nothing = Right <$> closeOutChannel s
  streamWrite (OutStream s) (Just msg) = do
    ret <- writeChannel s $ encodeMessage msg
    pure $ if ret == 0 then Right () else Left "writeChannel failed"
  {-# INLINE streamWrite #-}

instance Message o => StreamOutput o (BidiStream i o) where
  streamWrite (BidiStream (_, o)) = streamWrite o
  {-# INLINE streamWrite #-}

type UnaryHandler i o = ServerContext -> i -> IO o
type ClientStreamHandler i o = ServerContext -> InStream i -> IO o
type ServerStreamHandler i o a = ServerContext -> i -> OutStream o -> IO a
type BidiStreamHandler i o a = ServerContext -> BidiStream i o -> IO a

data RpcHandler where
  UnaryHandler
    :: (Message i, Message o) => UnaryHandler i o -> RpcHandler
  ClientStreamHandler
    :: (Message i, Message o) => ClientStreamHandler i o -> RpcHandler
  ServerStreamHandler
    :: (Message i, Message o) => ServerStreamHandler i o a -> RpcHandler
  BidiStreamHandler
    :: (Message i, Message o) => BidiStreamHandler i o a -> RpcHandler

instance Show RpcHandler where
  show (UnaryHandler _)        = "<UnaryHandler>"
  show (ClientStreamHandler _) = "<ClientStreamHandler>"
  show (ServerStreamHandler _) = "<ServerStreamHandler>"
  show (BidiStreamHandler _)   = "<BidiStreamHandler>"

handlerCStreamingType :: RpcHandler -> Word8
handlerCStreamingType (UnaryHandler _)        = C_StreamingType_NonStreaming
handlerCStreamingType (ClientStreamHandler _) = C_StreamingType_ClientStreaming
handlerCStreamingType (ServerStreamHandler _) = C_StreamingType_ServerStreaming
handlerCStreamingType (BidiStreamHandler _)   = C_StreamingType_BiDiStreaming

data ServiceHandler = ServiceHandler
  { rpcMethod        :: !GrpcMethod
  , rpcHandler       :: !RpcHandler
  , rpcUseThreadPool :: !Bool
  } deriving (Show)

-- | Switch to a thread_pool to run the Handler. The may only useful for unary
-- handler.
handlerUseThreadPool :: ServiceHandler -> ServiceHandler
handlerUseThreadPool handler = handler{rpcUseThreadPool = True}

unary
  :: (HasMethod s m, Message i, Message o)
  => GRPC s m
  -> UnaryHandler i o
  -> ServiceHandler
unary grpc handler =
  ServiceHandler{ rpcMethod = getGrpcMethod grpc
                , rpcHandler = UnaryHandler handler
                , rpcUseThreadPool = False
                }

clientStream
  :: (HasMethod s m, Message i, Message o)
  => GRPC s m
  -> ClientStreamHandler i o
  -> ServiceHandler
clientStream grpc handler =
  ServiceHandler{ rpcMethod = getGrpcMethod grpc
                , rpcHandler = ClientStreamHandler handler
                , rpcUseThreadPool = False
                }

serverStream
  :: (HasMethod s m, Message i, Message o)
  => GRPC s m
  -> ServerStreamHandler i o a
  -> ServiceHandler
serverStream grpc handler =
  ServiceHandler{ rpcMethod = getGrpcMethod grpc
                , rpcHandler = ServerStreamHandler handler
                , rpcUseThreadPool = False
                }

bidiStream
  :: (HasMethod s m, Message i, Message o)
  => GRPC s m
  -> BidiStreamHandler i o a
  -> ServiceHandler
bidiStream grpc handler =
  ServiceHandler{ rpcMethod = getGrpcMethod grpc
                , rpcHandler = BidiStreamHandler handler
                , rpcUseThreadPool = False
                }

-------------------------------------------------------------------------------

processorCallback :: [RpcHandler] -> ProcessorCallback
processorCallback handlers request_ptr response_ptr = do
  req <- peek request_ptr
  -- the cpp side already makes the bound check
  let handler = handlers !! requestHandlerIdx req   -- TODO: use vector to gain O(1) access
  case handler of
    UnaryHandler hd -> unaryCallback req hd response_ptr
    ClientStreamHandler hd -> void $ forkIO $ clientStreamCallback req hd response_ptr
    ServerStreamHandler hd -> void $ forkIO $ serverStreamCallback req hd response_ptr
    BidiStreamHandler hd -> void $ forkIO $ bidiStreamCallback req hd response_ptr

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

clientStreamCallback
  :: (Message o)
  => Request -> ClientStreamHandler i o -> Ptr Response -> IO ()
clientStreamCallback Request{..} hd response_ptr =
  let !readerChan = fromMaybe (error x) requestReadChannel
      !writerChan = fromMaybe (error x) requestWriteChannel
      x = "LogicError: This should never happen, call client stream with empty channel!"
      action = do
        replyBs <- encodeMessage <$> hd requestServerContext (InStream readerChan)
        -- NOTE: requestWriteChannel is closed on the cpp side
        ret <- writeChannel writerChan replyBs
        unless (ret == 0) $ Ex.throwIO $
          ServerException "Unexpected happened, send client streaming response failed!"
      clean = closeInChannel readerChan
   in void $ catchGrpcError' response_ptr clean action

serverStreamCallback
  :: (Message i)
  => Request
  -> ServerStreamHandler i o a
  -> Ptr Response
  -> IO ()
serverStreamCallback Request{..} hd response_ptr =
  let !writerChan = fromMaybe (error x) requestWriteChannel
      x = "LogicError: This should never happen, call server stream with empty channel!"
      stream = OutStream writerChan
      e_requestMsg = decodeMessage requestPayload
      action =
        case e_requestMsg of
          Left errmsg      -> parsingReqErrReply response_ptr (BSC.pack errmsg)
          Right requestMsg -> void $ hd requestServerContext requestMsg stream
      clean = closeOutChannel writerChan
   in void $ catchGrpcError' response_ptr clean action

-- TODO: before we close all channels, we should wait WriteChannel to flush all.
bidiStreamCallback
  :: Request
  -> BidiStreamHandler i o a
  -> Ptr Response
  -> IO ()
bidiStreamCallback req hd response_ptr =
  let !readerChan = fromMaybe (error x) (requestReadChannel req)
      !writerChan = fromMaybe (error x) (requestWriteChannel req)
      x = "LogicError: This should never happen, call bidi stream with empty channel!"
      stream = BidiStream (InStream readerChan, OutStream writerChan)
      action = void $ hd (requestServerContext req) stream
      -- We only need to close OutChannel
      clean = closeOutChannel writerChan
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
{-# INLINABLE whileM #-}
{-# SPECIALISE whileM :: IO Bool -> IO () #-}

bs2str :: ByteString -> String
bs2str = Text.unpack . Text.decodeUtf8
{-# INLINE bs2str #-}
