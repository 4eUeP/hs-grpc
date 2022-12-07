{-# LANGUAGE MagicHash #-}

-- Apis from https://grpc.github.io/grpc/cpp/classgrpc_1_1_generic_server_context.html

module HsGrpc.Server.Context
  ( serverContextPeer
  , findClientMetadata
  ) where

import           Data.ByteString              (ByteString)
import           Data.ByteString.Short        (ShortByteString)
import           Foreign.Ptr                  (Ptr, nullPtr)
import           GHC.Exts                     (ByteArray#)
import qualified HsForeign                    as HF

import           HsGrpc.Server.Internal.Types (ServerContext (..))

-------------------------------------------------------------------------------

-- | Return the peer uri in a bytestring.
--
-- WARNING: this value is never authenticated or subject to any security
-- related code. It must not be used for any authentication related
-- functionality. Instead, use auth_context.
serverContextPeer :: ServerContext -> IO ByteString
serverContextPeer ctx = HF.unsafePeekStdString =<< serverContext_peer ctx

-- TODO
-- serverContextClientMetadata :: ServerContext -> IO ()
-- serverContextClientMetadata = undefined

-- | Finds a value with key equivalent to key from the initial metadata sent
-- from the client. If there are several elements with the key in the metadata,
-- any of them may be returned.
--
-- It is safe to use this method after initial metadata has been received,
-- Calls always begin with the client sending initial metadata, so this is safe
-- to access as soon as the call has begun on the server side.
findClientMetadata :: ServerContext -> ShortByteString -> IO (Maybe ByteString)
findClientMetadata ctx key = HF.withShortByteString key $ \ba# len -> do
  p <- serverContext_client_metadata_find ctx ba# len
  if p /= nullPtr
     then Just <$> HF.unsafePeekStdString p
     else pure Nothing

-------------------------------------------------------------------------------

foreign import ccall unsafe "serverContext_peer"
  serverContext_peer :: ServerContext -> IO (Ptr HF.StdString)

foreign import ccall unsafe "serverContext_client_metadata_find"
  serverContext_client_metadata_find
    :: ServerContext
    -> ByteArray# -> Int
    -> IO (Ptr HF.StdString)
