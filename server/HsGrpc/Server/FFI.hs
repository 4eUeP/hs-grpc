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
    -> Ptr SslServerCredentialsOptions
    -> Int
    -- ^ parallelism
    -> IO (Ptr CppAsioServer)

foreign import ccall unsafe "shutdown_asio_server"
  shutdown_asio_server :: Ptr CppAsioServer -> IO ()

foreign import ccall unsafe "&delete_asio_server"
  delete_asio_server_fun :: FunPtr (Ptr CppAsioServer -> IO ())

foreign import ccall safe "run_asio_server"
  run_asio_server
    :: Ptr CppAsioServer
    -> Ptr (Ptr Word8) -> Ptr Int -> Ptr Word8{- StreamingType-} -> Int
    -> FunPtr ProcessorCallback
    -> CInt  -- ^ fd onStarted
    -> IO ()
