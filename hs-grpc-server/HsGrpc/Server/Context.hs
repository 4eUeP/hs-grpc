-- Apis from https://grpc.github.io/grpc/cpp/classgrpc_1_1_generic_server_context.html

module HsGrpc.Server.Context
  ( serverContextPeer
  ) where

import           Data.ByteString              (ByteString)
import           Foreign.Ptr                  (Ptr)
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

-------------------------------------------------------------------------------

foreign import ccall unsafe "serverContext_peer"
  serverContext_peer :: ServerContext -> IO (Ptr HF.StdString)
