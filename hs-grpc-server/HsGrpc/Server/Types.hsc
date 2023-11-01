{-# LANGUAGE BangPatterns    #-}
{-# LANGUAGE CPP             #-}
{-# LANGUAGE MagicHash       #-}
{-# LANGUAGE PatternSynonyms #-}

module HsGrpc.Server.Types
  ( ServerOptions (..)
  , defaultServerOpts

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

    -- * AuthTokens
  , AuthTokens
  , basicAuthTokens
  , withAuthTokens  -- XXX: this function should be in a Internal module

    -- * Interceptors
  , CServerInterceptorFactory
  , ServerInterceptor (..)

    -- * Channel arguments
  , ChannelArg
  , ChanArgValue (..)
  , mk_GRPC_ARG_KEEPALIVE_TIME_MS
  , mk_GRPC_ARG_KEEPALIVE_TIMEOUT_MS
  , mk_GRPC_ARG_KEEPALIVE_PERMIT_WITHOUT_CALLS
  , mk_GRPC_ARG_HTTP2_MIN_RECV_PING_INTERVAL_WITHOUT_DATA_MS
  , mk_GRPC_ARG_HTTP2_MAX_PINGS_WITHOUT_DATA
  , mk_GRPC_ARG_HTTP2_MAX_PING_STRIKES
  , withChannelArgs  -- XXX: this function should be in a Internal module

    -- * Internal Types
  , Request (..)
  , Response (..)
  , defResponse
  , CoroLock
  , releaseCoroLock
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
import           Control.Monad                 (forM_)
import           Data.ByteString               (ByteString)
import           Data.ByteString.Short         (ShortByteString)
import qualified Data.ByteString.Unsafe        as BS
import           Data.Maybe                    (isJust)
import           Data.ProtoLens.Service.Types  (StreamingType (..))
import           Data.Text                     (Text)
import           Data.Word                     (Word64, Word8)
import           Foreign.C.Types
import           Foreign.Marshal.Alloc
import           Foreign.Marshal.Array
import           Foreign.Ptr
import           Foreign.StablePtr             (StablePtr)
import           Foreign.Storable              (Storable (..))
import           GHC.Conc                      (PrimMVar)
import qualified HsForeign                     as HF

import           HsGrpc.Common.Foreign.Channel
import           HsGrpc.Server.Internal.Types

#include <grpc/grpc.h>
#include "hs_grpc_server.h"

-------------------------------------------------------------------------------

data ServerOptions = ServerOptions
  { serverHost         :: !ShortByteString
  , serverPort         :: !Int
  , serverParallelism  :: !Int
  , serverSslOptions   :: !(Maybe SslServerCredentialsOptions)
  , serverAuthTokens   :: ![ByteString]
  , serverOnStarted    :: !(Maybe (IO ()))
  , serverInterceptors :: ![ServerInterceptor]
  , serverChannelArgs  :: ![ChannelArg]
    -- The following options are considering as internal
  , serverInternalChannelSize :: !Word
  }

defaultServerOpts :: ServerOptions
defaultServerOpts = ServerOptions
  { serverHost = "127.0.0.1"
  , serverPort = 50051
  , serverParallelism = 0
  , serverSslOptions = Nothing
  , serverAuthTokens = []
  , serverOnStarted = Nothing
  , serverInterceptors = []
  , serverChannelArgs = []
  , serverInternalChannelSize = 2
  }

instance Show ServerOptions where
  show ServerOptions{..} =
    let notifyFn f = if isJust f then "<Function>" else "Nothing"
     in "{" <> "host: " <> show serverHost <> ", "
            <> "port: " <> show serverPort <> ", "
            <> "parallelism: " <> show serverParallelism <> ", "
            <> "sslOptions: " <> show serverSslOptions <> ", "
            <> "channelArgs: " <> show serverChannelArgs <> ", "
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

newtype CoroLock = CoroLock (Ptr ())
  deriving (Show)

-- CoroLock should never be NULL. However, I recheck it inside the c function.
releaseCoroLock :: CoroLock -> IO Int
releaseCoroLock lock = HF.withPrimAsyncFFI @Int (release_corolock lock)

foreign import ccall unsafe "release_corolock"
  release_corolock
    :: CoroLock -> StablePtr PrimMVar -> Int -> Ptr Int -> IO ()

data Request = Request
  { requestPayload       :: ByteString
  , requestHandlerIdx    :: Int
  , requestReadChannel   :: Maybe ChannelIn
  , requestWriteChannel  :: Maybe ChannelOut
  , requestCoroLock      :: CoroLock
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
    coroLock <- (#peek hsgrpc::server_request_t, coro_lock) ptr
    serverContext <- (#peek hsgrpc::server_request_t, server_context) ptr
    return $ Request{ requestPayload       = payload
                    , requestHandlerIdx    = handleIdx
                    , requestReadChannel   = channelIn
                    , requestWriteChannel  = channelOut
                    , requestCoroLock      = CoroLock coroLock
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
    errmsg_ptr <- HF.maybeNewStdString responseErrorMsg
    (#poke hsgrpc::server_response_t, error_msg) ptr errmsg_ptr
    errdetails_ptr <- HF.maybeNewStdString responseErrorDetails
    (#poke hsgrpc::server_response_t, error_details) ptr errdetails_ptr

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
-- Auth tokens

newtype AuthTokens = AuthTokens { unAuthTokens :: [ByteString] }
  deriving (Show, Eq)

-- > bash$ echo -n "user:passwd" | base64
-- > dXNlcjpwYXNzd2Q=
--
-- > basicAuthTokens ["dXNlcjpwYXNzd2Q="]
basicAuthTokens :: [ByteString] -> AuthTokens
basicAuthTokens = AuthTokens . map ("Basic " <>)

instance Storable AuthTokens where
  sizeOf _ = (#size hsgrpc::hs_auth_tokens_t)
  alignment _ = (#alignment hsgrpc::hs_auth_tokens_t)
  peek _ptr = error "Unimplemented"
  poke _ _ = error "Unimplemented, use withAuthTokens instead"

withAuthTokens :: AuthTokens -> (Ptr AuthTokens -> IO a) -> IO a
withAuthTokens tokens f =
  allocaBytesAligned (sizeOf tokens) (alignment tokens) $ \ptr ->
    HF.withByteStringList (unAuthTokens tokens) $ \ds ls l -> do
      (#poke hsgrpc::hs_auth_tokens_t, datas) ptr ds
      (#poke hsgrpc::hs_auth_tokens_t, sizes) ptr ls
      (#poke hsgrpc::hs_auth_tokens_t, len) ptr l
      f ptr

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

-------------------------------------------------------------------------------
-- Grpc channel arguments
--
-- https://grpc.github.io/grpc/core/group__grpc__arg__keys.html

data ChanArgValue
  = ChanArgValueInt CInt
  | ChanArgValueString ShortByteString
  deriving (Show, Eq)

newtype ChannelArg = ChannelArg (ShortByteString, ChanArgValue)
  deriving (Eq)

instance Show ChannelArg where
  show (ChannelArg (key, ChanArgValueInt val)) =
    "(" <> show key <> "," <> show val <> ")"
  show (ChannelArg (key, ChanArgValueString val)) =
    "(" <> show key <> "," <> show val <> ")"

instance Storable ChannelArg where
  sizeOf _ = (#size hsgrpc::hs_grpc_channel_arg_t)
  alignment _ = (#alignment hsgrpc::hs_grpc_channel_arg_t)
  peek _ptr = error "Unimplemented"
  poke ptr (ChannelArg (key, val)) = do
    key_ptr <- HF.newStdStringFromShort key  -- should be deleted on cpp side
    (#poke hsgrpc::hs_grpc_channel_arg_t, key) ptr key_ptr
    case val of
      ChanArgValueInt i -> do
        (#poke hsgrpc::hs_grpc_channel_arg_t, type)
            ptr
            ((#const static_cast<uint8_t>(hsgrpc::GrpcChannelArgValType::Int)) :: Word8)
        (#poke hsgrpc::hs_grpc_channel_arg_t, value.int_value)
            ptr i
      ChanArgValueString s -> do
        (#poke hsgrpc::hs_grpc_channel_arg_t, type)
            ptr
            ((#const static_cast<uint8_t>(hsgrpc::GrpcChannelArgValType::String)) :: Word8)
        value_ptr <- HF.newStdStringFromShort s  -- should be deleted on cpp side
        (#poke hsgrpc::hs_grpc_channel_arg_t, value.string_value) ptr value_ptr

withChannelArgs :: [ChannelArg] -> (Ptr ChannelArg -> Int -> IO a) -> IO a
withChannelArgs args f = do
  let !len = length args
  allocaArray @ChannelArg len $ \ptr -> do
    forM_ (zip [0..len-1] args) $ \(i, arg) -> pokeElemOff ptr i arg
    f ptr len

#define hsc_mk_chan_args(c, vt, vw) \
  hsc_printf("pattern %s :: ShortByteString\n", #c, #c);          \
  hsc_printf("pattern %s = ", #c); hsc_const_str(c);              \
  hsc_printf("\n");                                               \
  hsc_printf("mk_%s :: %s -> ChannelArg\n", #c, #vt);             \
  hsc_printf("mk_%s v = ChannelArg (%s, %s v)\n", #c, #c, #vw);

-- | After a duration of this time the client/server pings its peer to see if
-- the transport is still alive. Int valued, milliseconds.
#mk_chan_args GRPC_ARG_KEEPALIVE_TIME_MS, CInt, ChanArgValueInt

-- | After waiting for a duration of this time, if the keepalive ping sender
-- does not receive the ping ack, it will close the transport. Int valued,
-- milliseconds.
#mk_chan_args GRPC_ARG_KEEPALIVE_TIMEOUT_MS, CInt, ChanArgValueInt

-- | Is it permissible to send keepalive pings from the client without any
-- outstanding streams. Int valued, 0(false)/1(true).
#mk_chan_args GRPC_ARG_KEEPALIVE_PERMIT_WITHOUT_CALLS, CInt, ChanArgValueInt

-- | Minimum allowed time between a server receiving successive ping frames
-- without sending any data/header frame. Int valued, milliseconds
#mk_chan_args GRPC_ARG_HTTP2_MIN_RECV_PING_INTERVAL_WITHOUT_DATA_MS, CInt, ChanArgValueInt

-- | How many pings can the client send before needing to send a
-- data/header frame? (0 indicates that an infinite number of
-- pings can be sent without sending a data frame or header frame)
#mk_chan_args GRPC_ARG_HTTP2_MAX_PINGS_WITHOUT_DATA, CInt, ChanArgValueInt

-- | How many misbehaving pings the server can bear before sending goaway and
-- closing the transport? (0 indicates that the server can bear an infinite
-- number of misbehaving pings)
#mk_chan_args GRPC_ARG_HTTP2_MAX_PING_STRIKES, CInt, ChanArgValueInt

-------------------------------------------------------------------------------
-- Interceptors

-- This following underlying type is exported by design so that users can make
-- their own ffi from grpc cpp interceptor apis.

data CServerInterceptorFactory

-- TODO
data ServerInterceptorFn

data ServerInterceptor
  = ServerInterceptorFromPtr (Ptr CServerInterceptorFactory)
  | ServerInterceptor ServerInterceptorFn
