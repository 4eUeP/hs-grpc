{-# LANGUAGE CPP #-}

module HsGrpc.Server.Message
  ( Proto.Message
  , encodeMessage
  , decodeMessage
  , decodeMessageOrError
  ) where

import           Data.ByteString      (ByteString)

-------------------------------------------------------------------------------
#ifdef HSGRPC_USE_PROTOSUITE
-------------------------------------------------------------------------------

import           Data.Bifunctor       (first)
import qualified Data.ByteString.Lazy as BSL
import qualified Proto3.Suite         as Proto

encodeMessage :: Proto.Message msg => msg -> ByteString
encodeMessage = BSL.toStrict . Proto.toLazyByteString
{-# INLINE encodeMessage #-}

decodeMessage :: Proto.Message msg => ByteString -> Either String msg
decodeMessage bs = first show (Proto.fromByteString bs)
{-# INLINE decodeMessage #-}

-------------------------------------------------------------------------------
#else
-------------------------------------------------------------------------------

import qualified Data.ProtoLens as Proto

encodeMessage :: Proto.Message msg => msg -> ByteString
encodeMessage = Proto.encodeMessage
{-# INLINE encodeMessage #-}

decodeMessage :: Proto.Message msg => ByteString -> Either String msg
decodeMessage = Proto.decodeMessage
{-# INLINE decodeMessage #-}

-------------------------------------------------------------------------------
#endif
-------------------------------------------------------------------------------

decodeMessageOrError :: Proto.Message msg => ByteString -> msg
decodeMessageOrError = either error id . decodeMessage
