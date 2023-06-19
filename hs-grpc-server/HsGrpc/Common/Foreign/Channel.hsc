module HsGrpc.Common.Foreign.Channel
  ( CppChannelIn
  , CppChannelOut
  , ChannelIn
  , ChannelOut
  , peekMaybeCppChannelIn
  , peekMaybeCppChannelOut
  , readChannel
  , writeChannel
  , closeOutChannel
  , closeInChannel
  ) where

import           Data.ByteString          (ByteString)
import qualified Data.ByteString.Internal as BS
import           Data.Primitive
import           Data.Word
import           Foreign.ForeignPtr
import           Foreign.Ptr              (FunPtr, nullPtr)
import           Foreign.StablePtr        (StablePtr)
import           Foreign.Storable
import           GHC.Conc
import           HsForeign                (withAsyncFFI, withPrimAsyncFFI)

#include "hs_grpc_server.h"

-------------------------------------------------------------------------------

data CppChannelIn   -- channel_in_t
data CppChannelOut  -- channel_out_t

type ChannelIn = ForeignPtr CppChannelIn
type ChannelOut = ForeignPtr CppChannelOut

peekMaybeCppChannelIn :: Ptr CppChannelIn -> IO (Maybe ChannelIn)
peekMaybeCppChannelIn ptr =
  if ptr == nullPtr then pure Nothing
                    else Just <$> newForeignPtr delete_in_channel_fun ptr

peekMaybeCppChannelOut :: Ptr CppChannelOut -> IO (Maybe ChannelOut)
peekMaybeCppChannelOut ptr =
  if ptr == nullPtr then pure Nothing
                    else Just <$> newForeignPtr delete_out_channel_fun ptr

readChannel :: ChannelIn -> IO (Maybe ByteString)
readChannel chan = withForeignPtr chan $ \ptr -> channelCbDataBuf <$>
  withAsyncFFI channelCbDataSize peekChannelCbData (read_channel ptr)

writeChannel :: ChannelOut -> ByteString -> IO Int
writeChannel chan (BS.PS bs offset len) =
  withForeignPtr chan $ \ptr ->
  withForeignPtr bs $ \bs' -> do
    withPrimAsyncFFI @Int (write_channel ptr bs' offset len)

closeInChannel :: ChannelIn -> IO ()
closeInChannel chan = withForeignPtr chan close_in_channel

closeOutChannel :: ChannelOut -> IO ()
closeOutChannel chan = withForeignPtr chan close_out_channel

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

foreign import ccall unsafe "close_in_channel"
  close_in_channel :: Ptr CppChannelIn -> IO ()

foreign import ccall unsafe "&delete_in_channel"
  delete_in_channel_fun :: FunPtr (Ptr CppChannelIn -> IO ())

foreign import ccall unsafe "close_out_channel"
  close_out_channel :: Ptr CppChannelOut -> IO ()

foreign import ccall unsafe "&delete_out_channel"
  delete_out_channel_fun :: FunPtr (Ptr CppChannelOut -> IO ())

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
  buff <- if ec == 0
            then do buff_data <- (#peek hsgrpc::read_channel_cb_data_t, buff_data) ptr
                    buff_size <- (#peek hsgrpc::read_channel_cb_data_t, buff_size) ptr
                    -- FIXME: Here we assume that if errcode is 0, then the ptr will
                    -- not be NULL. Do we need to check it?
                    buf' <- newForeignPtr finalizerGprFree buff_data
                    pure $ Just (BS.PS buf' 0 buff_size)
            else pure Nothing
  pure $ ChannelCbData ec buff

foreign import ccall unsafe "grpc/support/alloc.h &gpr_free"
  finalizerGprFree :: FinalizerPtr a
