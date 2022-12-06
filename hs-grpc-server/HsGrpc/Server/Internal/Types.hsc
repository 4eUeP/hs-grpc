module HsGrpc.Server.Internal.Types where

import           Foreign.Ptr (Ptr)

-------------------------------------------------------------------------------
-- (TODO) Grpc ServerContext

data CServerContext

newtype ServerContext = ServerContext {unServerContext :: (Ptr CServerContext)}
  deriving (Show)
