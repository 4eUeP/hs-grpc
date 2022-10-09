module HsGrpc.Common.Foreign.Channel
  ( CppChannelIn
  , CppChannelOut
  , readCppChannel
  , writeCppChannel
  , closeOutChannel
  , closeInChannel
  ) where

import           Data.ByteString          (ByteString)
import qualified Data.ByteString.Internal as BS
import           Data.Primitive
import           Data.Word
import           Foreign.ForeignPtr
import           Foreign.StablePtr        (StablePtr)
import           Foreign.Storable
import           GHC.Conc
import           HsForeign                (unsafePeekStdString, withAsyncFFI,
                                           withPrimAsyncFFI)

#include "hs_grpc_server.h"

-------------------------------------------------------------------------------

data CppChannelIn
data CppChannelOut

readCppChannel :: Ptr CppChannelIn -> IO (Maybe ByteString)
readCppChannel ptr =
  channelCbDataBuf <$> withAsyncFFI channelCbDataSize peekChannelCbData (read_channel ptr)

writeCppChannel :: Ptr CppChannelOut -> ByteString -> IO Int
writeCppChannel ptr (BS.PS bs offset len) =
  withForeignPtr bs $ \bs' -> do
    withPrimAsyncFFI @Int (write_channel ptr bs' offset len)

foreign import ccall unsafe "write_channel"
  write_channel
    :: Ptr CppChannelOut
    -> Ptr Word8 -> Int -> Int
    -> StablePtr PrimMVar -> Int
    -> Ptr Int
    -> IO ()

foreign import ccall unsafe "read_channel"
  read_channel
    :: Ptr CppChannelIn
    -> StablePtr PrimMVar -> Int
    -> Ptr ChannelCbData
    -> IO ()

foreign import ccall unsafe "close_out_channel"
  closeOutChannel :: Ptr CppChannelOut -> IO ()

foreign import ccall unsafe "close_in_channel"
  closeInChannel :: Ptr CppChannelIn -> IO ()

-------------------------------------------------------------------------------

data ChannelCbData = ChannelCbData
  { channelCbDataCode :: Int
  , channelCbDataBuf  :: Maybe ByteString
  } deriving (Show)

channelCbDataSize :: Int
channelCbDataSize = (#size hsgrpc::read_channel_cb_data_t)

peekChannelCbData :: Ptr ChannelCbData -> IO ChannelCbData
peekChannelCbData ptr = do
  ec <- (#peek hsgrpc::read_channel_cb_data_t, ec) ptr
  buf <- if ec == 0
            then do buf' <- (#peek hsgrpc::read_channel_cb_data_t, buf) ptr
                    -- FIXME: Here we assume that if errcode is 0, then the ptr will
                    -- not be NULL. Do we need to check it?
                    Just <$> unsafePeekStdString buf'
            else pure Nothing
  pure $ ChannelCbData ec buf
