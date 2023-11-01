module Main (main) where

import           Control.Monad
import           Data.ByteString     (ByteString)
import qualified Data.ByteString     as BS
import           Data.Either
import           Data.ProtoLens      (defMessage)
import           Lens.Micro

import           HsGrpc.Common.Log
import           HsGrpc.Server
import           HsGrpc.Server.Types
import           Proto.Auth          as P
import           Proto.Auth_Fields   as P
import           Proto.Msg           as P
import           Proto.Msg_Fields    as P

main :: IO ()
main = do
  let tokens = [ "dXNlcjpwYXNzd2Q="  -- echo -n "user:passwd" | base64
               , "dXNlcjE6cGFzc3dkMQ=="  -- echo -n "user1:passwd1" | base64
               ]
  --sslOptions <- Just <$>readTlsPemFile
  --                "tests/cases/credentials/localhost.key"
  --                "tests/cases/credentials/localhost.crt"
  --                Nothing
                  -- (Just "tests/cases/credentials/root.crt")
  sslOptions <- pure Nothing

  let opts = defaultServerOpts
        { serverHost = "127.0.0.1"
        , serverPort = 50051
        , serverSslOptions = sslOptions
        , serverAuthTokens = tokens
        , serverParallelism = 1
        , serverOnStarted = Just onStarted
        }
  runServer opts handlers

readTlsPemFile
  :: String -> String -> Maybe String
  -> IO SslServerCredentialsOptions
readTlsPemFile keyPath certPath caPath = do
  key <- BS.readFile keyPath
  cert <- BS.readFile certPath
  ca <- mapM BS.readFile caPath
  let authType = maybe GrpcSslDontRequestClientCertificate
                       (const GrpcSslRequestAndRequireClientCertificateAndVerify)
                       caPath
  pure $ SslServerCredentialsOptions{ pemKeyCertPairs = [(key, cert)]
                                    , pemRootCerts = ca
                                    , clientAuthType = authType
                                    }


onStarted :: IO ()
onStarted = putStrLn "Server listening on 0.0.0.0:50051"


handlers :: [ServiceHandler]
handlers =
  [ unary (GRPC :: GRPC P.AuthService "unary") handleUnary
  , clientStream (GRPC :: GRPC P.AuthService "clientStream") handleClientStream
  , serverStream (GRPC :: GRPC P.AuthService "serverStream") handleServerStream
  , bidiStream (GRPC :: GRPC P.AuthService "bidiStream") handleBidiStream
  ]

handleUnary :: UnaryHandler P.Request P.Reply
handleUnary _ctx req = pure $ defMessage & P.msg .~ (req ^. P.msg)

handleClientStream :: ClientStreamHandler P.Request P.Reply
handleClientStream = undefined

handleServerStream :: ServerStreamHandler P.Request P.Reply ()
handleServerStream = undefined

handleBidiStream :: BidiStreamHandler P.Request P.Reply ()
handleBidiStream _ctx stream = whileM $ do
  m_req <- streamRead stream
  case m_req of
    Just req -> do
      let reply = defMessage & P.msg .~ ("hi, " <> req ^. P.msg)
      isRight <$> streamWrite stream (Just reply)
    Nothing -> putStrLn "Client closed" >> pure False
