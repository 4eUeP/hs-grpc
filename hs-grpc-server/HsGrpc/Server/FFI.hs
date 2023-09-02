{-# LANGUAGE MagicHash #-}

module HsGrpc.Server.FFI where

import           Data.Word
import           Foreign.C
import           Foreign.Ptr
import           GHC.Exts

import           HsGrpc.Server.Types

-------------------------------------------------------------------------------

data CppAsioServer

-- NOTE: "unsafe" is required
foreign import ccall unsafe "new_asio_server"
  new_asio_server
    :: ByteArray# -> Int
    -- ^ host, host_len
    -> Int
    -- ^ port
    -> Int
    -- ^ parallelism
    -> Ptr SslServerCredentialsOptions
    -- ^ tls options
    -> Ptr (Ptr CServerInterceptorFactory) -> Int
    -- ^ Interceptors
    -> IO (Ptr CppAsioServer)

foreign import ccall unsafe "shutdown_asio_server"
  shutdown_asio_server :: Ptr CppAsioServer -> IO ()

foreign import ccall unsafe "&delete_asio_server"
  delete_asio_server_fun :: FunPtr (Ptr CppAsioServer -> IO ())

foreign import ccall safe "run_asio_server"
  run_asio_server
    :: Ptr CppAsioServer
    -> Ptr (Ptr Word8)
    -- ^ Key of method_handlers: data(NOT null terminated)
    -> Ptr Int
    -- ^ Key of method_handlers: size
    -> Ptr Word8
    -- ^ Value of method_handlers: StreamingType
    -> Ptr CBool
    -- ^ Value of method_handlers: use_thread_pool
    -> Ptr CBool
    -- ^ Value of method_handlers: is_short_unary
    -> Int
    -- ^ Total size of method_handlers
    -> FunPtr ProcessorCallback
    -> CInt  -- ^ fd onStarted
    -> CSize -- ^ Max buffer size for the internal streaming channel
    -> Int   -- ^ Max time of unary
    -> IO ()
