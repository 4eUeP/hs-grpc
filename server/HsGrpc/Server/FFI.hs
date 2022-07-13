{-# LANGUAGE MagicHash #-}

module HsGrpc.Server.FFI where

import           Foreign.Ptr
import           GHC.Exts

import           HsGrpc.Server.Types

-------------------------------------------------------------------------------

data CppAsioServer

-- NOTE: "unsafe" is required
foreign import ccall unsafe "new_asio_server"
  new_asio_server :: ByteArray# -> Int -> Int -> Int -> IO (Ptr CppAsioServer)

foreign import ccall unsafe "shutdown_asio_server"
  shutdown_asio_server :: Ptr CppAsioServer -> IO ()

foreign import ccall unsafe "&delete_asio_server"
  delete_asio_server_fun :: FunPtr (Ptr CppAsioServer -> IO ())

foreign import ccall safe "run_asio_server"
  run_asio_server :: Ptr CppAsioServer -> FunPtr ProcessorCallback -> IO ()

-------------------------------------------------------------------------------

data CppServer

-- NOTE: "unsafe" is required
foreign import ccall unsafe "new_server"
  new_server :: ByteArray# -> Int -> Int -> Int -> IO (Ptr CppServer)

foreign import ccall unsafe "shutdown_server"
  shutdown_server :: Ptr CppServer -> IO ()

foreign import ccall unsafe "&delete_server"
  delete_server_fun :: FunPtr (Ptr CppServer -> IO ())

foreign import ccall safe "run_server"
  run_server :: Ptr CppServer -> FunPtr ProcessorCallback -> IO ()
