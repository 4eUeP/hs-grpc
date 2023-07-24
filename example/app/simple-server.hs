{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Concurrent      (threadDelay)
import           Data.Either             (isRight)
import           Data.ProtoLens          (defMessage)
import qualified Data.Text               as Text
import           Lens.Micro

import           HsGrpc.Common.Log
import           HsGrpc.Server
import           HsGrpc.Server.Context
import           Proto.Example        as P
import           Proto.Example_Fields as P

handlers :: [ServiceHandler]
handlers =
  [ unary (GRPC :: GRPC P.Example "unary") handleUnary
  , clientStream (GRPC :: GRPC P.Example "clientStream") handleClientStream
  , serverStream (GRPC :: GRPC P.Example "serverStream") handleServerStream
  , bidiStream (GRPC :: GRPC P.Example "bidiStream") handleBidiStream
  ]

-- Get context
--
--handleUnary1 :: UnaryHandler P.Request P.Reply
--handleUnary1 ctx req = do
--  print =<< serverContextPeer ctx
--  print =<< findClientMetadata ctx "user-agent"
--  pure $ defMessage & P.msg .~ (req ^. P.msg)

handleUnary :: UnaryHandler P.Request P.Reply
handleUnary _ req = pure $ defMessage & P.msg .~ (req ^. P.msg)

handleClientStream :: ClientStreamHandler P.Request P.Reply
handleClientStream _ctx stream = go (0 :: Int)
  where
    go n = do
      m_req <- streamRead stream
      case m_req of
        Just req -> do
          putStrLn $ "Recv client request " <> show req
          go $! (n + 1)
        Nothing -> do
          let reply = "Received " <> Text.pack (show n) <> " requests."
          pure $ defMessage & P.msg .~ reply

handleServerStream :: ServerStreamHandler P.Request P.Reply ()
handleServerStream _ctx req stream = do
  putStrLn $ "Received client request " <> show req
  whileM $ do
    threadDelay 1000000
    pure True
    --putStrLn "Sending reply..."
    --let reply = defMessage & P.msg .~ ("hi, " <> req ^. P.msg)
    --isRight <$> streamWrite stream (Just reply)
  putStrLn "Server streaming done."

handleBidiStream :: BidiStreamHandler P.Request P.Reply ()
handleBidiStream _ctx stream = whileM $ do
  m_req <- streamRead stream
  case m_req of
    Just req -> do
      let reply = defMessage & P.msg .~ ("hi, " <> req ^. P.msg)
      isRight <$> streamWrite stream (Just reply)
    Nothing -> putStrLn "Client closed" >> pure False

onStarted :: IO ()
onStarted = putStrLn "Server listening on 0.0.0.0:50051"

main :: IO ()
main = do
  let opts = defaultServerOpts{ serverHost = "0.0.0.0"
                              , serverPort = 50051
                              , serverParallelism = 0
                              , serverSslOptions = Nothing
                              , serverOnStarted = Just onStarted
                              }
  gprSetLogVerbosity GprLogSeverityDebug
  runServer opts handlers
