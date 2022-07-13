{-# LANGUAGE CPP             #-}
{-# LANGUAGE PatternSynonyms #-}

module HsGrpc.Common.Log
  ( GprLogSeverity
  , pattern GprLogSeverityDebug
  , pattern GprLogSeverityInfo
  , pattern GprLogSeverityError
  , gprSetLogVerbosity
  ) where

#include <grpc/support/log.h>

-------------------------------------------------------------------------------

newtype GprLogSeverity = GprLogSeverity { unGprLogSeverity :: Int }
  deriving (Eq, Read, Show)

#enum GprLogSeverity, GprLogSeverity \
  , pattern GprLogSeverityDebug = GPR_LOG_SEVERITY_DEBUG \
  , pattern GprLogSeverityInfo  = GPR_LOG_SEVERITY_INFO  \
  , pattern GprLogSeverityError = GPR_LOG_SEVERITY_ERROR

{-# COMPLETE
    GprLogSeverityDebug
  , GprLogSeverityInfo
  , GprLogSeverityError
  #-}

foreign import ccall unsafe "gpr_set_log_verbosity"
  gprSetLogVerbosity :: GprLogSeverity -> IO ()
