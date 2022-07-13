{-# LANGUAGE CPP             #-}
{-# LANGUAGE PatternSynonyms #-}

module HsGrpc.Server.Types
  ( ServerOptions (..)

  -- * Exceptions
  , ServerException (..)
  , GrpcError (..)
  , throwGrpcError

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

    -- * Internal Types
  , Request (..)
  , Response (..)
  , defResponse
    -- ** StreamingType
  , StreamingType (..)
  , pattern C_StreamingType_NonStreaming
  , pattern C_StreamingType_ClientStreaming
  , pattern C_StreamingType_ServerStreaming
  , pattern C_StreamingType_BiDiStreaming
  , streamingTypeToCType
  , streamingTypeFromCType
    -- ** Processor
  , ProcessorCallback
  , mkProcessorCallback
  , withProcessorCallback
  ) where

import           Control.Exception             (Exception, bracket, throwIO)
import           Data.ByteString               (ByteString)
import           Data.ByteString.Short         (ShortByteString)
import qualified Data.ByteString.Unsafe        as BS
import           Data.Maybe                    (isJust)
import           Data.ProtoLens.Service.Types  (StreamingType (..))
import           Data.Text                     (Text)
import           Data.Word                     (Word64, Word8)
import           Foreign.Ptr                   (FunPtr, Ptr, freeHaskellFunPtr,
                                                nullPtr)
import           Foreign.Storable              (Storable (..))
import qualified HsForeign                     as HF

import           HsGrpc.Common.Foreign.Channel

#include "hs_grpc.h"

-------------------------------------------------------------------------------

data ServerOptions = ServerOptions
  { serverHost        :: !ShortByteString
  , serverPort        :: !Int
  , serverParallelism :: !Int
  , serverOnStarted   :: !(Maybe (IO ()))
  }

instance Show ServerOptions where
  show ServerOptions{..} =
    let notifyFn f = if isJust f then "<Function>" else "Nothing"
     in "{" <> "host: " <> show serverHost <> ", "
            <> "port: " <> show serverPort <> ", "
            <> "parallelism: " <> show serverParallelism <> ", "
            <> "onStartedEvent: " <> notifyFn serverOnStarted
     <> "}"

-------------------------------------------------------------------------------

type ProcessorCallback = Ptr Request -> Ptr Response -> IO ()

foreign import ccall "wrapper"
  mkProcessorCallback :: ProcessorCallback -> IO (FunPtr ProcessorCallback)

withProcessorCallback :: ProcessorCallback
                      -> (FunPtr ProcessorCallback -> IO a)
                      -> IO a
withProcessorCallback cb = bracket (mkProcessorCallback cb) freeHaskellFunPtr

-------------------------------------------------------------------------------

data Request = Request
  { requestPayload      :: ByteString
  , requestHandlerIdx   :: Int
  , requestReadChannel  :: Ptr CppChannelIn
  , requestWriteChannel :: Ptr CppChannelOut
  } deriving (Show)

instance Storable Request where
  sizeOf _ = (#size hsgrpc::server_request_t)
  alignment _ = (#alignment hsgrpc::server_request_t)
  peek ptr = do
    data_ptr <- (#peek hsgrpc::server_request_t, data) ptr
    data_size <- (#peek hsgrpc::server_request_t, data_size) ptr :: IO Word64
    handleIdx <- (#peek hsgrpc::server_request_t, handler_idx) ptr
    -- NOTE: This value will have no finalizer associated with it, and will not
    -- be garbage collected by Haskell.
    --
    -- If the original CStringLen is later modified, this change will be
    -- reflected in the resulting ByteString.
    --
    -- BS.unsafePackCStringLen (nullPtr, 0) === ""
    payload <- BS.unsafePackCStringLen (data_ptr, fromIntegral data_size)
    channelIn <- (#peek hsgrpc::server_request_t, channel_in) ptr
    channelOut <- (#peek hsgrpc::server_request_t, channel_out) ptr
    return $ Request{ requestPayload      = payload
                    , requestHandlerIdx   = handleIdx
                    , requestReadChannel  = channelIn
                    , requestWriteChannel = channelOut
                    }
  poke ptr Request{..} = do
    (data_ptr, data_size) <- HF.mallocFromByteString requestPayload
    (#poke hsgrpc::server_request_t, data) ptr data_ptr
    (#poke hsgrpc::server_request_t, data_size) ptr data_size
    (#poke hsgrpc::server_request_t, channel_in) ptr requestReadChannel
    (#poke hsgrpc::server_request_t, channel_out) ptr requestWriteChannel

data Response = Response
  { responseData         :: Maybe ByteString
  , responseStatusCode   :: StatusCode
  , responseErrorMsg     :: Maybe ByteString
  , responseErrorDetails :: Maybe ByteString
  } deriving (Show)

defResponse :: Response
defResponse = Response
  { responseData = Nothing
  , responseStatusCode = StatusOK
  , responseErrorMsg = Nothing
  , responseErrorDetails = Nothing
  }

instance Storable Response where
  sizeOf _ = (#size hsgrpc::server_response_t)
  alignment _ = (#alignment hsgrpc::server_response_t)
  peek ptr = do
    data_ptr <- (#peek hsgrpc::server_response_t, data) ptr
    data_size <- (#peek hsgrpc::server_response_t, data_size) ptr :: IO Word64
    payload <- if data_ptr == nullPtr
                  then pure Nothing
                  else Just <$> BS.unsafePackCStringLen (data_ptr, fromIntegral data_size)
    status_code <- (#peek hsgrpc::server_response_t, status_code) ptr
    error_msg' <- (#peek hsgrpc::server_response_t, error_msg) ptr
    error_msg <- if error_msg' /= nullPtr
                    then Just <$> HF.unsafePeekStdString error_msg'
                    else pure Nothing
    error_details' <- (#peek hsgrpc::server_response_t, error_details) ptr
    error_details <- if error_details' /= nullPtr
                        then Just <$> HF.unsafePeekStdString error_details'
                        else pure Nothing
    return $ Response{ responseData = payload
                     , responseStatusCode = StatusCode status_code
                     , responseErrorMsg = error_msg
                     , responseErrorDetails = error_details
                     }
  poke ptr Response{..} = do
    (data_ptr, data_size) <- HF.mallocFromMaybeByteString responseData
    (#poke hsgrpc::server_response_t, data) ptr data_ptr
    (#poke hsgrpc::server_response_t, data_size) ptr data_size
    (#poke hsgrpc::server_response_t, status_code) ptr (unStatusCode responseStatusCode)
    errmsg_ptr <- maybeNewStdString responseErrorMsg
    (#poke hsgrpc::server_response_t, error_msg) ptr errmsg_ptr
    errdetails_ptr <- maybeNewStdString responseErrorDetails
    (#poke hsgrpc::server_response_t, error_details) ptr errdetails_ptr

-- TODO: upgrade foreign package to use HS.maybeNewStdString
maybeNewStdString :: Maybe ByteString -> IO (Ptr HF.StdString)
maybeNewStdString Nothing   = pure nullPtr
maybeNewStdString (Just bs) = HF.withByteString bs $ HF.hs_new_std_string

-------------------------------------------------------------------------------

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

throwGrpcError :: GrpcStatus -> IO a
throwGrpcError = throwIO . GrpcError

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

newtype StatusCode = StatusCode { unStatusCode :: Int }
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
