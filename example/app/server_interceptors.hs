{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import           Data.ProtoLens       (defMessage)
import           Foreign.Ptr          (Ptr)
import           Lens.Micro

import           HsGrpc.Common.Log
import           HsGrpc.Server
import           HsGrpc.Server.Types
import           Proto.Example        as P
import           Proto.Example_Fields as P

handlers :: [ServiceHandler]
handlers = [unary (GRPC :: GRPC P.Example "unary") handleUnary]

handleUnary :: UnaryHandler P.Request P.Reply
handleUnary _ctx req = pure $ defMessage & P.msg .~ (req ^. P.msg)

onStarted :: IO ()
onStarted = putStrLn "Server listening on 0.0.0.0:50051"

main :: IO ()
main = do
  sendMessageInterceptor <- ServerInterceptorFromPtr <$> sendMessageInterceptorFactory
  let opts = defaultServerOpts{ serverHost = "0.0.0.0"
                              , serverPort = 50051
                              , serverParallelism = 0
                              , serverSslOptions = Nothing
                              , serverOnStarted = Just onStarted
                              , serverInterceptors = [sendMessageInterceptor]
                              }
  gprSetLogVerbosity GprLogSeverityInfo
  runServer opts handlers

foreign import ccall unsafe "sendMessageInterceptorFactory"
  sendMessageInterceptorFactory :: IO (Ptr CServerInterceptorFactory)
