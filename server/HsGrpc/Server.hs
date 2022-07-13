{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds    #-}
{-# LANGUAGE GADTs        #-}
{-# LANGUAGE TypeFamilies #-}

module HsGrpc.Server
  ( GRPC (..)
    --
  , ServerOptions (..)
  , AsioServer
  , newAsioServer
  , runAsioGrpc
  , newServer
  , runGrpc

    -- * Handlers
  , UnaryHandler
  , ServiceHandler (..)
  , unary
  ) where

import qualified Control.Concurrent.Async       as Async
import           Control.Exception              (bracket, throwIO)
import           Data.ByteString                (ByteString)
import qualified Data.ByteString.Char8          as BSC
import           Data.ByteString.Short          (ShortByteString)
import qualified Data.ByteString.Short.Internal as BS
import           Data.Kind                      (Type)
import qualified Data.List                      as List
import           Data.ProtoLens.Service.Types   (HasMethod, MethodName,
                                                 Service (..))
import           Data.Proxy                     (Proxy (..))
import qualified Data.Text                      as Text
import qualified Data.Text.Encoding             as Text
import           Foreign.ForeignPtr             (ForeignPtr, newForeignPtr,
                                                 withForeignPtr)
import           Foreign.Ptr                    (nullPtr)
import           Foreign.Storable               (peek, poke)
import           GHC.TypeLits                   (Symbol, symbolVal)

import           HsGrpc.Server.FFI
import           HsGrpc.Server.Message          (Message, decodeMessage,
                                                 encodeMessage)
import           HsGrpc.Server.Types

-------------------------------------------------------------------------------

data GRPC (s :: Type) (m :: Symbol) = GRPC

getGrpcMethod :: (HasMethod s m) => GRPC s m -> ByteString
getGrpcMethod rpc =
  "/" <> srvPkg rpc Proxy <> "." <> srvName rpc Proxy <> "/"
      <> method rpc Proxy
  where
    srvPkg :: (Service s) => GRPC s m -> Proxy (ServicePackage s) -> ByteString
    srvPkg _ p = BSC.pack $ symbolVal p

    srvName :: (Service s) => GRPC s m -> Proxy (ServiceName s) -> ByteString
    srvName _ p = BSC.pack $ symbolVal p

    method :: (HasMethod s m) => GRPC s m -> Proxy (MethodName s m) -> ByteString
    method _ p = BSC.pack $ symbolVal p
{-# INLINE getGrpcMethod #-}

-------------------------------------------------------------------------------

data ServerOptions = ServerOptions
  { serverHost        :: !ShortByteString
  , serverPort        :: !Int
  , serverParallelism :: !Int
  } deriving (Show)

type AsioServer = ForeignPtr CppAsioServer

newAsioServer :: ServerOptions -> IO AsioServer
newAsioServer ServerOptions{..} = do
  let !(BS.SBS host) = serverHost
      host_len = BS.length serverHost
  ptr <- new_asio_server host host_len serverPort serverParallelism
  if (ptr == nullPtr) then throwIO $ ServerException "newAsioServer failed!"
                      else newForeignPtr delete_asio_server_fun ptr

runAsioGrpc :: AsioServer -> [ServiceHandler] -> IO ()
runAsioGrpc server handlers =
  withForeignPtr server $ \server_ptr ->
  withProcessorCallback (processorCallback handlers) $ \cbPtr ->
    let start = run_asio_server server_ptr cbPtr
        stop a = shutdown_asio_server server_ptr >> Async.wait a
     in bracket (Async.async start) stop Async.wait

type Server = ForeignPtr CppServer

newServer :: ServerOptions -> IO Server
newServer ServerOptions{..} = do
  let !(BS.SBS host) = serverHost
      host_len = BS.length serverHost
  ptr <- new_server host host_len serverPort serverParallelism
  if (ptr == nullPtr) then throwIO $ ServerException "newServer failed!"
                      else newForeignPtr delete_server_fun ptr

runGrpc :: Server -> [ServiceHandler] -> IO ()
runGrpc server handlers =
  withForeignPtr server $ \server_ptr ->
  withProcessorCallback (processorCallback handlers) $ \cbPtr ->
    let start = run_server server_ptr cbPtr
        stop a = shutdown_server server_ptr >> Async.wait a
     in bracket (Async.async start) stop Async.wait

-------------------------------------------------------------------------------
-- Handlers

type UnaryHandler i o = i -> IO o

data ServiceHandler where
  UnaryHandler :: (Message i, Message o) => ByteString -> UnaryHandler i o -> ServiceHandler

instance Show ServiceHandler where
  show (UnaryHandler method _) = "Handler for " <> (Text.unpack $ Text.decodeUtf8 method)

unary
  :: (HasMethod s m, Message i, Message o)
  => GRPC s m
  -> UnaryHandler i o
  -> ServiceHandler
unary rpc handler = UnaryHandler (getGrpcMethod rpc) handler

processorCallback :: [ServiceHandler] -> ProcessorCallback
processorCallback handlers request_ptr response_ptr = do
  Request{..} <- peek request_ptr
  -- TODO: use vector or map
  let handle_m =
        List.find (\(UnaryHandler method _) -> method == requestMethod) handlers
  case handle_m of
    -- TODO
    Nothing -> error "No such handler!"
    Just (UnaryHandler _ hd) -> do
      let e_requestMsg = decodeMessage requestPayload
      case e_requestMsg of
        -- TODO
        Left errmsg -> error errmsg
        Right requestMsg -> do
          replyMsg <- hd requestMsg
          -- TODO
          let response = Response { responseStreamingType = NonStreaming
                                  , responseData = Just $ encodeMessage replyMsg
                                  }
          poke response_ptr response
