{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Data.ProtoLens          (defMessage)
import           Lens.Micro

import           HsGrpc.Server
import           Proto.Helloworld        as P
import           Proto.Helloworld_Fields as P

handlers :: [ServiceHandler]
handlers = [ unary (GRPC :: GRPC P.Greeter "sayHello") handleSayHello
           , unary (GRPC :: GRPC P.Greeter "echo") handleEcho
           ]

handleEcho :: P.EchoMsg -> IO P.EchoMsg
handleEcho req = pure req

handleSayHello :: P.HelloRequest -> IO P.HelloReply
handleSayHello req = pure $ defMessage & P.msg .~ (req ^. P.name)
{-# INLINE handleSayHello #-}

main :: IO ()
main = do
  let serverOptions = ServerOptions { serverHost = "0.0.0.0"
                                    , serverPort = 50051
                                    , serverParallelism = 1
                                    }
  server <- newServer serverOptions
  runGrpc server handlers
