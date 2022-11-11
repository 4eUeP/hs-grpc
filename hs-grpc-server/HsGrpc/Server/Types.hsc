{-# LANGUAGE CPP             #-}
{-# LANGUAGE PatternSynonyms #-}

module HsGrpc.Server.Types
  ( ServerOptions (..)

  , ServerException (..)

  -- * Grpc ServerContext
  , ServerContext

  -- * Status
  , GrpcError (..)
  , throwGrpcError
  -- ** GrpcStatus
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

    -- * Grpc Ssl
  , SslServerCredentialsOptions (..)
  , withSslServerCredentialsOptions
    -- ** ClientCertificateRequestType
    --
    -- $grpcSslClientCertificateRequestType
  , GrpcSslClientCertificateRequestType
  , pattern GrpcSslDontRequestClientCertificate
  , pattern GrpcSslRequestClientCertificateButDontVerify
  , pattern GrpcSslRequestClientCertificateAndVerify
  , pattern GrpcSslRequestAndRequireClientCertificateButDontVerify
  , pattern GrpcSslRequestAndRequireClientCertificateAndVerify

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
import           Foreign.Marshal.Alloc         (allocaBytesAligned)
import           Foreign.Ptr                   (FunPtr, Ptr, freeHaskellFunPtr,
                                                nullPtr)
import           Foreign.Storable              (Storable (..))
import qualified HsForeign                     as HF

import           HsGrpc.Common.Foreign.Channel

#include "hs_grpc_server.h"

-------------------------------------------------------------------------------

data ServerOptions = ServerOptions
  { serverHost        :: !ShortByteString
  , serverPort        :: !Int
  , serverParallelism :: !Int
  , serverSslOptions  :: !(Maybe SslServerCredentialsOptions)
  , serverOnStarted   :: !(Maybe (IO ()))
  }

instance Show ServerOptions where
  show ServerOptions{..} =
    let notifyFn f = if isJust f then "<Function>" else "Nothing"
     in "{" <> "host: " <> show serverHost <> ", "
            <> "port: " <> show serverPort <> ", "
            <> "parallelism: " <> show serverParallelism <> ", "
            <> "sslOptions: " <> show serverSslOptions <> ", "
            <> "onStartedEvent: " <> notifyFn serverOnStarted
     <> "}"

newtype ServerException = ServerException Text
  deriving (Show, Eq)
instance Exception ServerException

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
  { requestPayload       :: ByteString
  , requestHandlerIdx    :: Int
  , requestReadChannel   :: Maybe ChannelIn
  , requestWriteChannel  :: Maybe ChannelOut
  , requestServerContext :: ServerContext
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
    channelIn <- peekMaybeCppChannelIn =<<
      (#peek hsgrpc::server_request_t, channel_in) ptr
    channelOut <- peekMaybeCppChannelOut =<<
      (#peek hsgrpc::server_request_t, channel_out) ptr
    serverContext <- (#peek hsgrpc::server_request_t, server_context) ptr
    return $ Request{ requestPayload       = payload
                    , requestHandlerIdx    = handleIdx
                    , requestReadChannel   = channelIn
                    , requestWriteChannel  = channelOut
                    , requestServerContext = ServerContext serverContext
                    }
  poke _ptr _req = error "Request is not pokeable"

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
-- (TODO) Grpc ServerContext

data CServerContext

newtype ServerContext = ServerContext {unServerContext :: (Ptr CServerContext)}
  deriving (Show)

-------------------------------------------------------------------------------
-- GrpcSsl

data SslServerCredentialsOptions = SslServerCredentialsOptions
  { pemKeyCertPairs :: [(ByteString, ByteString)]
    -- ^ A list of pairs of the form [PEM-encoded private key, PEM-encoded
    -- certificate chain].
  , pemRootCerts   :: Maybe ByteString
    -- ^ An optional byte string of PEM-encoded client root certificates that
    -- the server will use to verify client authentication.
    --
    -- If Nothing, 'clientAuthType' must also NOT be
    -- 'GrpcSslRequestAndRequireClientCertificateAndVerify'.
  , clientAuthType :: GrpcSslClientCertificateRequestType
    -- ^ A type indicating how clients to be authenticated.
  } deriving (Show, Eq)

instance Storable SslServerCredentialsOptions where
  sizeOf _ = (#size hsgrpc::hs_ssl_server_credentials_options_t)
  alignment _ = (#alignment hsgrpc::hs_ssl_server_credentials_options_t)
  peek _ptr = error "Unimplemented"
  poke _ _ = error "NotPokeable, see withSslServerCredentialsOptions for alternative"

withSslServerCredentialsOptions
  :: SslServerCredentialsOptions
  -> (Ptr SslServerCredentialsOptions -> IO a)
  -> IO a
withSslServerCredentialsOptions o@SslServerCredentialsOptions{..} f =
  allocaBytesAligned (sizeOf o) (alignment o) $ \ptr ->
    HF.withMaybeByteString pemRootCerts $ \rootCertsPtr rootCertsLen ->
    HF.withByteStringList (map fst pemKeyCertPairs) $ \p1 l1 s1 ->
    HF.withByteStringList (map snd pemKeyCertPairs) $ \p2 l2 _the_same_as_s1 -> do
      (#poke hsgrpc::hs_ssl_server_credentials_options_t, pem_root_certs_data) ptr rootCertsPtr
      (#poke hsgrpc::hs_ssl_server_credentials_options_t, pem_root_certs_len) ptr rootCertsLen
      (#poke hsgrpc::hs_ssl_server_credentials_options_t, pem_private_key_datas) ptr p1
      (#poke hsgrpc::hs_ssl_server_credentials_options_t, pem_private_key_lens) ptr l1
      (#poke hsgrpc::hs_ssl_server_credentials_options_t, pem_cert_chain_datas) ptr p2
      (#poke hsgrpc::hs_ssl_server_credentials_options_t, pem_cert_chain_lens) ptr l2
      (#poke hsgrpc::hs_ssl_server_credentials_options_t, pem_key_cert_pairs_size) ptr s1
      (#poke hsgrpc::hs_ssl_server_credentials_options_t, client_certificate_request)
          ptr (unGrpcSslClientCertificateRequestType clientAuthType)
      f ptr

newtype GrpcSslClientCertificateRequestType = GrpcSslClientCertificateRequestType
  { unGrpcSslClientCertificateRequestType :: Int }
  deriving (Eq, Read, Show)

-- $grpcSslClientCertificateRequestType
--
-- * 'GrpcSslDontRequestClientCertificate'
--
-- Server does not request client certificate.
--
-- The certificate presented by the client is not checked by the server at all.
-- (A client may present a self signed or signed certificate or not present a
-- certificate at all and any of those option would be accepted)
--
-- * 'GrpcSslRequestClientCertificateButDontVerify'
--
-- Server requests client certificate but does not enforce that the client
-- presents a certificate.
--
-- If the client presents a certificate, the client authentication is left to
-- the application (the necessary metadata will be available to the application
-- via authentication context properties, see grpc_auth_context).
--
-- The client's key certificate pair must be valid for the SSL connection to be
-- established.
--
-- * 'GrpcSslRequestClientCertificateAndVerify'
--
-- Server requests client certificate but does not enforce that the client
-- presents a certificate.
--
-- If the client presents a certificate, the client authentication is done by
-- the gRPC framework. (For a successful connection the client needs to either
-- present a certificate that can be verified against the root certificate
-- configured by the server or not present a certificate at all)
--
-- The client's key certificate pair must be valid for the SSL connection to be
-- established.
--
-- * 'GrpcSslRequestAndRequireClientCertificateButDontVerify'
--
-- Server requests client certificate and enforces that the client presents a
-- certificate.
--
-- If the client presents a certificate, the client authentication is left to
-- the application (the necessary metadata will be available to the application
-- via authentication context properties, see grpc_auth_context).
--
-- The client's key certificate pair must be valid for the SSL connection to be
-- established.
--
-- * 'GrpcSslRequestAndRequireClientCertificateAndVerify'
--
-- Server requests client certificate and enforces that the client presents a
-- certificate.
--
-- The certificate presented by the client is verified by the gRPC framework.
-- (For a successful connection the client needs to present a certificate that
-- can be verified against the root certificate configured by the server)
--
-- The client's key certificate pair must be valid for the SSL connection to be
-- established.

#enum GrpcSslClientCertificateRequestType, GrpcSslClientCertificateRequestType \
  , pattern GrpcSslDontRequestClientCertificate = GRPC_SSL_DONT_REQUEST_CLIENT_CERTIFICATE \
  , pattern GrpcSslRequestClientCertificateButDontVerify = GRPC_SSL_REQUEST_CLIENT_CERTIFICATE_BUT_DONT_VERIFY \
  , pattern GrpcSslRequestClientCertificateAndVerify = GRPC_SSL_REQUEST_CLIENT_CERTIFICATE_AND_VERIFY \
  , pattern GrpcSslRequestAndRequireClientCertificateButDontVerify = GRPC_SSL_REQUEST_AND_REQUIRE_CLIENT_CERTIFICATE_BUT_DONT_VERIFY \
  , pattern GrpcSslRequestAndRequireClientCertificateAndVerify = GRPC_SSL_REQUEST_AND_REQUIRE_CLIENT_CERTIFICATE_AND_VERIFY

{-# COMPLETE
    GrpcSslDontRequestClientCertificate
  , GrpcSslRequestClientCertificateButDontVerify
  , GrpcSslRequestClientCertificateAndVerify
  , GrpcSslRequestAndRequireClientCertificateButDontVerify
  , GrpcSslRequestAndRequireClientCertificateAndVerify
  #-}

-------------------------------------------------------------------------------
-- Status

newtype GrpcError = GrpcError GrpcStatus
  deriving (Show, Eq)
instance Exception GrpcError

throwGrpcError :: GrpcStatus -> IO a
throwGrpcError = throwIO . GrpcError

-- $grpcStatus
--
-- For details, see: https://grpc.github.io/grpc/cpp/classgrpc_1_1_status.html

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
