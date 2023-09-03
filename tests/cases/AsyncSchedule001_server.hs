module Main (main) where

import           Control.Concurrent
import           Control.Monad
import           Data.Either
import           Data.ProtoLens             (defMessage)
import           Lens.Micro
import           System.IO.Unsafe

import           HsGrpc.Common.Log
import           HsGrpc.Server
import           Proto.AsyncSchedule        as P
import           Proto.AsyncSchedule_Fields as P

main :: IO ()
main = do
  let opts = defaultServerOpts
        { serverHost = "0.0.0.0"
        , serverPort = 50051
        , serverParallelism = 1  -- Use 1 is to test concurrency. (For modern CPUs, it seems enough)
        , serverOnStarted = Just onStarted
        }
  --gprSetLogVerbosity GprLogSeverityDebug
  runServer opts $ handlers

onStarted :: IO ()
onStarted = putStrLn "Server listening on 0.0.0.0:50051"

handlers :: [ServiceHandler]
handlers =
  -- With using 'shortUnary', the test case should not pass.
  [ unary (GRPC :: GRPC P.Service "slowUnary") handleSlowUnary
  , unary (GRPC :: GRPC P.Service "depUnary") handleDepUnary
  , bidiStream (GRPC :: GRPC P.Service "bidiStream") handleBidiStream
  ]

handleSlowUnary :: UnaryHandler P.Request P.Reply
handleSlowUnary _ctx _req = do
  putStrLn "-> Put"
  threadDelay 1000000
  putStrLn "-> Put done"
  pure $ defMessage & P.msg .~ "hi"

-- NOTE: not thread-safe
notifyMVar :: MVar ()
notifyMVar = unsafePerformIO $ newEmptyMVar
{-# NOINLINE notifyMVar #-}

exitedMVar :: MVar ()
exitedMVar = unsafePerformIO $ newEmptyMVar
{-# NOINLINE exitedMVar #-}

handleDepUnary :: UnaryHandler P.Request P.Reply
handleDepUnary _ctx req = do
  putStrLn "-> Notify stream exit"
  putMVar notifyMVar ()
  putStrLn "-> Wait stream exit"
  void $ takeMVar exitedMVar
  pure $ defMessage & P.msg .~ "done"

handleBidiStream :: BidiStreamHandler P.Request P.Reply ()
handleBidiStream _ctx stream = do
  m_req <- streamRead stream
  case m_req of
    Just req -> do
      putStrLn $ "-> Wait exit notification"
      _ <- takeMVar notifyMVar
      putStrLn $ "-> Put exited notification"
      putMVar exitedMVar ()
      let reply = defMessage & P.msg .~ ("hi, " <> req ^. P.msg)
      r <- streamWrite stream (Just reply)
      putStrLn $ "-> Write response " <> show r
    Nothing -> putStrLn "Client closed"
