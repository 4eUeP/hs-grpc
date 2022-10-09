module HsGrpc.Common.Utils
  ( getSystemEventManager'
  , withFdEventNotification

    -- Re-export
  , Lifetime (..)
  , Fd (..)
  ) where

import           Control.Exception  (Exception, bracket, throw)
import           Control.Monad      (when)
import           Foreign.C          (CInt (..), throwErrno)
import           GHC.Event          (EventManager, Lifetime (..), evtRead,
                                     getSystemEventManager, registerFd,
                                     unregisterFd)
import           System.Posix.IO    (closeFd)
import           System.Posix.Types (Fd (..))

-------------------------------------------------------------------------------

-- Copy from https://github.com/facebookincubator/hsthrift/blob/main/common/util/Util/Fd.hs
-- with slight modification.

-- Exception to throw when unable to get the event manager
getSystemEventManager' :: Exception e => e -> IO EventManager
getSystemEventManager' err = maybe (throw err) return =<< getSystemEventManager

-- | Uses a file descriptor and GHC's event manager to run a callback
-- once the file descriptor is written to. Is less expensive than a new FFI
-- call from C++ back into Haskell.
--
-- NOTE: if you want to put the Fd to haskell ffi, it should be a safe ffi.
withFdEventNotification
  :: EventManager
  -> Maybe (IO ())  -- ^ The callback to run on fd write
  -> Lifetime       -- ^ OneShot or MultiShot
  -> (Fd -> IO a)   -- ^ Action to run with the file descriptor to write to
  -> IO a
withFdEventNotification _ Nothing _ action = action (Fd (-1))
withFdEventNotification evm (Just callback) lifetime action =
  withEventFd $ \fd -> do
    bracket (registerFd evm (\_ _ -> callback) fd evtRead lifetime)
            (unregisterFd evm)
            (const $ action fd)

withEventFd :: (Fd -> IO a) -> IO a
withEventFd = bracket
  (do fd <- c_eventfd 0 0
      when (fd == -1) $ throwErrno "eventFd"
      return $ Fd fd)
  closeFd

foreign import ccall unsafe "eventfd"
  c_eventfd :: CInt -> CInt -> IO CInt
