{-# LANGUAGE CPP             #-}
{-# LANGUAGE PatternSynonyms #-}

module HsGrpc.Server.Types
  ( Request (..)
  , Response (..)
  , StreamingType (..)
  , ProcessorCallback
  , mkProcessorCallback
  , withProcessorCallback

  -- * Exceptions
  , ServerException (..)
  , GrpcError (..)

  -- * GRPC Status
  --
  -- $grpcStatus
  , GrpcStatus (..)
  , StatusCode
  , pattern StatusOK
  , pattern StatusCancelled
  , pattern StatusUnknown
  , pattern StatusInvalidArgument
  , pattern StatusDeadlineExceeded
  , pattern StatusNotFound
  , pattern StatusAlreadyExists
  , pattern StatusPermissionDenied
  , pattern StatusUnauthenticated
  , pattern StatusResourceExhausted
  , pattern StatusFailedPrecondition
  , pattern StatusAborted
  , pattern StatusOutOfRange
  , pattern StatusUnimplemented
  , pattern StatusInternal
  , pattern StatusUnavailable
  , pattern StatusDataLoss
  , pattern StatusDoNotUse
  ) where

import           Control.Exception            (Exception, bracket)
import           Data.ByteString              (ByteString)
import qualified Data.ByteString.Unsafe       as BS
import           Data.ProtoLens.Service.Types (StreamingType (..))
import           Data.Text                    (Text)
import           Data.Word                    (Word64, Word8)
import           Foreign.C.String             (CString)
import           Foreign.Marshal              (copyBytes, mallocBytes)
import           Foreign.Ptr                  (FunPtr, Ptr, freeHaskellFunPtr,
                                               nullPtr)
import           Foreign.Storable             (Storable (..))

#include "hs_grpc.h"

-------------------------------------------------------------------------------

type ProcessorCallback = Ptr Request -> Ptr Response -> IO ()

foreign import ccall "wrapper"
  mkProcessorCallback :: ProcessorCallback -> IO (FunPtr ProcessorCallback)

withProcessorCallback :: ProcessorCallback
                      -> (FunPtr ProcessorCallback -> IO a)
                      -> IO a
withProcessorCallback cb = bracket (mkProcessorCallback cb) freeHaskellFunPtr

data Request = Request
  { requestMethod  :: ByteString
  , requestPayload :: ByteString
  } deriving (Show)

instance Storable Request where
  sizeOf _ = (#size hsgrpc::server_request_t)
  alignment _ = (#alignment hsgrpc::server_request_t)
  peek ptr = do
    data_ptr    <- (#peek hsgrpc::server_request_t, data) ptr
    data_size   <- (#peek hsgrpc::server_request_t, data_size) ptr :: IO Word64
    method_ptr  <- (#peek hsgrpc::server_request_t, method) ptr
    method_size <- (#peek hsgrpc::server_request_t, method_size) ptr :: IO Word64
    method  <- BS.unsafePackCStringLen (method_ptr, fromIntegral method_size)
    payload <- BS.unsafePackCStringLen (data_ptr, fromIntegral data_size)
    return $ Request{ requestMethod=method, requestPayload=payload }
  poke ptr Request{..} = do
    (method_ptr, method_size) <- mallocFromByteString requestMethod
    (data_ptr, data_size)     <- mallocFromByteString requestPayload
    (#poke hsgrpc::server_request_t, data) ptr data_ptr
    (#poke hsgrpc::server_request_t, data_size) ptr data_size
    (#poke hsgrpc::server_request_t, method) ptr method_ptr
    (#poke hsgrpc::server_request_t, method_size) ptr method_size

data Response = Response
  { responseStreamingType :: StreamingType
  , responseData          :: Maybe ByteString
  } deriving (Show)

instance Storable Response where
  sizeOf _ = (#size hsgrpc::server_response_t)
  alignment _ = (#alignment hsgrpc::server_response_t)
  peek ptr = do
    streaming_type <- streamingTypeFromCType <$> (#peek hsgrpc::server_response_t, streaming_type) ptr
    data_ptr  <- (#peek hsgrpc::server_response_t, data) ptr
    data_size <- (#peek hsgrpc::server_response_t, data_size) ptr :: IO Word64
    payload <- if data_ptr == nullPtr
                  then pure Nothing
                  else Just <$> BS.unsafePackCStringLen (data_ptr, fromIntegral data_size)
    return $ Response{ responseStreamingType=streaming_type, responseData=payload }
  poke ptr Response{..} = do
    (data_ptr, data_size) <- mallocFromMaybeByteString responseData
    (#poke hsgrpc::server_response_t, streaming_type) ptr (streamingTypeToCType responseStreamingType)
    (#poke hsgrpc::server_response_t, data) ptr data_ptr
    (#poke hsgrpc::server_response_t, data_size) ptr data_size

pattern C_StreamingType_NonStreaming :: Word8
pattern C_StreamingType_NonStreaming = (#const static_cast<uint8_t>(hsgrpc::StreamingType::NonStreaming))

pattern C_StreamingType_ClientStreaming :: Word8
pattern C_StreamingType_ClientStreaming = (#const static_cast<uint8_t>(hsgrpc::StreamingType::ClientStreaming))

pattern C_StreamingType_ServerStreaming :: Word8
pattern C_StreamingType_ServerStreaming = (#const static_cast<uint8_t>(hsgrpc::StreamingType::ServerStreaming))

pattern C_StreamingType_BiDiStreaming :: Word8
pattern C_StreamingType_BiDiStreaming = (#const static_cast<uint8_t>(hsgrpc::StreamingType::BiDiStreaming))

{-# COMPLETE
    C_StreamingType_NonStreaming
  , C_StreamingType_ClientStreaming
  , C_StreamingType_ServerStreaming
  , C_StreamingType_BiDiStreaming
  #-}

streamingTypeToCType :: StreamingType -> Word8
streamingTypeToCType NonStreaming    = C_StreamingType_NonStreaming
streamingTypeToCType ClientStreaming = C_StreamingType_ClientStreaming
streamingTypeToCType ServerStreaming = C_StreamingType_ServerStreaming
streamingTypeToCType BiDiStreaming   = C_StreamingType_BiDiStreaming

streamingTypeFromCType :: Word8 -> StreamingType
streamingTypeFromCType C_StreamingType_NonStreaming    = NonStreaming
streamingTypeFromCType C_StreamingType_ClientStreaming = ClientStreaming
streamingTypeFromCType C_StreamingType_ServerStreaming = ServerStreaming
streamingTypeFromCType C_StreamingType_BiDiStreaming   = BiDiStreaming

-------------------------------------------------------------------------------

newtype ServerException = ServerException Text
  deriving (Show, Eq)
instance Exception ServerException

newtype GrpcError = GrpcError GrpcStatus
  deriving (Show, Eq)
instance Exception GrpcError

-------------------------------------------------------------------------------
-- gprc::Status

-- $grpcStatus
--
-- for details, see: https://grpc.github.io/grpc/cpp/classgrpc_1_1_status.html

data GrpcStatus = GrpcStatus
  { statusCode         :: StatusCode
  , statusErrorMsg     :: Maybe ByteString
  , statusErrorDetails :: Maybe ByteString
  } deriving (Show, Eq)

toCStatus :: GrpcStatus -> Ptr GrpcStatus
toCStatus = undefined

newtype StatusCode = StatusCode Int
  deriving (Eq, Read, Show)

#enum StatusCode, StatusCode \
  , pattern StatusOK                 = grpc::StatusCode::OK                    \
  , pattern StatusCancelled          = grpc::StatusCode::CANCELLED             \
  , pattern StatusUnknown            = grpc::StatusCode::UNKNOWN               \
  , pattern StatusInvalidArgument    = grpc::StatusCode::INVALID_ARGUMENT      \
  , pattern StatusDeadlineExceeded   = grpc::StatusCode::DEADLINE_EXCEEDED     \
  , pattern StatusNotFound           = grpc::StatusCode::NOT_FOUND             \
  , pattern StatusAlreadyExists      = grpc::StatusCode::ALREADY_EXISTS        \
  , pattern StatusPermissionDenied   = grpc::StatusCode::PERMISSION_DENIED     \
  , pattern StatusUnauthenticated    = grpc::StatusCode::UNAUTHENTICATED       \
  , pattern StatusResourceExhausted  = grpc::StatusCode::RESOURCE_EXHAUSTED    \
  , pattern StatusFailedPrecondition = grpc::StatusCode::FAILED_PRECONDITION   \
  , pattern StatusAborted            = grpc::StatusCode::ABORTED               \
  , pattern StatusOutOfRange         = grpc::StatusCode::OUT_OF_RANGE          \
  , pattern StatusUnimplemented      = grpc::StatusCode::UNIMPLEMENTED         \
  , pattern StatusInternal           = grpc::StatusCode::INTERNAL              \
  , pattern StatusUnavailable        = grpc::StatusCode::UNAVAILABLE           \
  , pattern StatusDataLoss           = grpc::StatusCode::DATA_LOSS             \
  , pattern StatusDoNotUse           = grpc::StatusCode::DO_NOT_USE

{-# COMPLETE
    StatusOK
  , StatusCancelled
  , StatusUnknown
  , StatusInvalidArgument
  , StatusDeadlineExceeded
  , StatusNotFound
  , StatusAlreadyExists
  , StatusPermissionDenied
  , StatusUnauthenticated
  , StatusResourceExhausted
  , StatusFailedPrecondition
  , StatusAborted
  , StatusOutOfRange
  , StatusUnimplemented
  , StatusInternal
  , StatusUnavailable
  , StatusDataLoss
  , StatusDoNotUse
  #-}

-------------------------------------------------------------------------------
-- Misc

mallocFromMaybeByteString :: Maybe ByteString -> IO (CString, Int)
mallocFromMaybeByteString (Just bs) = mallocFromByteString bs
mallocFromMaybeByteString Nothing = return (nullPtr, 0)

-- Do NOT forget to free the allocated memory.
mallocFromByteString :: ByteString -> IO (CString, Int)
mallocFromByteString bs =
  BS.unsafeUseAsCStringLen bs $ \(src, len) -> do
    buf <- mallocBytes len
    copyBytes buf src len
    return (buf, len)
