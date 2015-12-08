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
type UserSocket = H.HashMap User Socket
type HostUser   = H.HashMap HostName User

socketServer :: MVar UserSocket -> MVar HostUser -> IO ()
socketServer mus mhu = do
  sock <- socket AF_INET Stream 0
  setSocketOption sock ReuseAddr 1
--  setSocketOption sock KeepAlive 1
  bindSocket sock (SockAddrInet 8888 iNADDR_ANY)
  listen sock 2
  forever $ do
    conn <- accept sock
    forkIO $ runConn conn mus mhu

runConn :: (Socket, SockAddr) -> MVar UserSocket -> MVar HostUser -> IO ()
runConn (sock, (SockAddrInet _ host)) mus mhu = do
  hostUser <- readMVar mhu
  address  <- inet_ntoa host
  putStrLn $ "Received new connetion from " ++ (show address)

  case H.lookup address hostUser of
    Just user -> modifyMVar_ mus $ \userSocket -> do
         closeOld user userSocket
         return $ H.insert user sock userSocket
    Nothing -> close sock

closeOld :: User -> UserSocket -> IO ()
closeOld user userSocket =
  when (H.member user userSocket)
       (close (fromJust $ H.lookup user userSocket))

serializeMessage message = do
  let size = fromIntegral $ C.length message
  writeToByteString (writeInt32be size <> writeByteString message)

sendPush :: ByteString -> Socket -> IO ()
sendPush message socket = do
  putStrLn $ "Pushing: " ++ (show message)
  connected <- isConnected socket
  when connected (do
    let push = serializeMessage message
    void $ send socket push)

pingWorker :: MVar UserSocket -> IO ()
pingWorker mus = forever $ do
  sockets <- fmap H.elems (readMVar mus)
  mapM_ (sendPush "PING") sockets
  threadDelay (10 * 60 * 10^6) -- sleep 10 minutes

httpServer :: MVar UserSocket -> MVar HostUser -> IO ()
httpServer mus mhu = S.scotty 9000 $ do
  S.post "/enable" (do
    userid <- S.param "user_id" :: S.ActionM String
    host   <- S.param "from"    :: S.ActionM HostName

    liftIO $ do
      putStrLn $ "Enabling: " ++ (show userid)
      modifyMVar_ mhu $ \hostUser ->
        return $ H.insert host userid hostUser

      modifyMVar_ mus $ \userSocket -> do
        closeOld userid userSocket
        return $ H.delete userid userSocket

    S.status status200)

  S.post "/push" (do
    userid  <- S.param "user_id"
    message <- S.param "message"

    liftIO $ modifyMVar_ mus $ \userSocket -> do
      let socket = H.lookup userid userSocket
      when (isJust socket) (sendPush message (fromJust socket))
      return userSocket)

main :: IO ()
main = do
  mus <- newMVar H.empty
  mhu <- newMVar H.empty
  async $ httpServer mus mhu
  async $ pingWorker mus
  socketServer mus mhu
