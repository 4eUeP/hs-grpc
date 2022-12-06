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
import           Proto.Helloworld        as P
import           Proto.Helloworld_Fields as P

handlers :: [ServiceHandler]
handlers =
  [ unary (GRPC :: GRPC P.Greeter "echo") handleEcho
  , unary (GRPC :: GRPC P.Greeter "sayHello") handleSayHello
  , clientStream (GRPC :: GRPC P.Greeter "sayHelloClientStream") handleClientStreamSayHello
  , serverStream (GRPC :: GRPC P.Greeter "sayHelloServerStream") handleServerStreamSayHello
  , bidiStream (GRPC :: GRPC P.Greeter "sayHelloBiDiStream") handleBidiSayHello
  ]

handleEcho :: UnaryHandler P.EchoMsg P.EchoMsg
handleEcho _ctx = pure

handleSayHello :: UnaryHandler P.HelloRequest P.HelloReply
handleSayHello ctx req = do
  print =<< serverContextPeer ctx
  pure $ defMessage & P.msg .~ (req ^. P.name)

handleClientStreamSayHello :: ClientStreamHandler P.HelloRequest P.HelloReply
handleClientStreamSayHello _ctx stream = go (0 :: Int)
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

handleServerStreamSayHello :: ServerStreamHandler P.HelloRequest P.HelloReply ()
handleServerStreamSayHello _ctx req stream = do
  putStrLn $ "Received client request " <> show req
  whileM $ do
    threadDelay 1000000
    putStrLn "Sending reply..."
    let reply = defMessage & P.msg .~ ("hi, " <> req ^. P.name)
    isRight <$> streamWrite stream (Just reply)
  putStrLn "Server streaming done."

handleBidiSayHello :: BidiStreamHandler P.HelloRequest P.HelloReply ()
handleBidiSayHello _ctx stream = whileM $ do
  m_req <- streamRead stream
  case m_req of
    Just req -> do
      let reply = defMessage & P.msg .~ ("hi, " <> req ^. P.name)
      isRight <$> streamWrite stream (Just reply)
    Nothing -> putStrLn "Client closed" >> pure False

onStarted :: IO ()
onStarted = putStrLn "Server listening on 0.0.0.0:50051"

main :: IO ()
main = do
  let opts = ServerOptions { serverHost = "0.0.0.0"
                           , serverPort = 50051
                           , serverParallelism = 0
                           , serverSslOptions = Nothing
                           , serverOnStarted = Just onStarted
                           }
  gprSetLogVerbosity GprLogSeverityInfo
  runServer opts handlers
