{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Blaze.ByteString.Builder
import           Blaze.ByteString.Builder.ByteString
import           Blaze.ByteString.Builder.Int
import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Concurrent.MVar
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.ByteString                     (ByteString)
import qualified Data.ByteString.Char8               as C
import qualified Data.HashMap.Strict                 as H
import           Data.Maybe
import           Data.Monoid
import           Network.HTTP.Types.Status
import           Network.Socket                      hiding (recv, recvFrom,
                                                      send, sendTo)
import           Network.Socket.ByteString
import qualified Web.Scotty                          as S

type User       = String
type UserSocket = MVar (H.HashMap User Socket)
type HostUser   = MVar (H.HashMap HostName User)

socketServer mus mhu = do
  sock <- socket AF_INET Stream 0
  setSocketOption sock ReuseAddr 1
  setSocketOption sock KeepAlive 1
  bindSocket sock (SockAddrInet 8888 iNADDR_ANY)
  listen sock 2
  forever $ do
    conn <- accept sock
    forkIO $ runConn conn mus mhu

runConn :: (Socket, SockAddr) -> UserSocket -> HostUser -> IO ()
runConn (sock, (SockAddrInet _ host)) mus mhu = do
  hostUser <- readMVar mhu
  address  <- inet_ntoa host
  putStrLn $ "Received new connetion from " ++ (show address)

  case H.lookup address hostUser of
    Just user -> modifyMVar_ mus $ \userSocket -> do
         when (H.member user userSocket) (close (fromJust $ H.lookup user userSocket))
         return $ H.insert user sock userSocket
    Nothing -> close sock

serializeMessage message = do
  let size = fromIntegral $ C.length message
  writeToByteString (writeInt32be size <> writeByteString message)

sendPush :: Socket -> ByteString -> IO ()
sendPush socket message = do
  putStrLn $ "Pushing: " ++ (show message)
  connected <- isConnected socket
  when connected (do
    let push = serializeMessage message
    void $ send socket push)

pingWorker :: UserSocket -> IO ()
pingWorker mus = forever $ do
  sockets <- fmap H.elems (readMVar mus)
  let pingMessage = serializeMessage "PING"
  mapM_ ping sockets
  threadDelay (10 * 60 * 10^6) -- sleep 10 minutes
  where
    ping socket = do
      connected <- isConnected socket
      when connected (void $ send socket "p")

httpServer :: UserSocket -> HostUser -> IO ()
httpServer mus mhu = S.scotty 9000 $ do
  S.post "/enable" (do
    userid <- S.param "user_id" :: S.ActionM String
    host   <- S.param "from"    :: S.ActionM HostName

    liftIO $ putStrLn $ "Enabling: " ++ (show userid)
    liftIO $ modifyMVar_ mhu $ \hostUser ->
      return $ H.insert host userid hostUser
    S.status status200)

  S.post "/push" (do
    userid  <- S.param "user_id"
    message <- S.param "message"

    liftIO $ modifyMVar_ mus $ \userSocket -> do
      let socket = H.lookup userid userSocket
      when (isJust socket) (sendPush (fromJust socket) message)
      return userSocket)

main :: IO ()
main = do
  mus <- newMVar H.empty
  mhu <- newMVar H.empty
  async $ httpServer mus mhu
  async $ pingWorker mus
  socketServer mus mhu
