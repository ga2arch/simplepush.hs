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
import           System.IO
import           System.Log.Formatter
import           System.Log.Handler                  (setFormatter)
import           System.Log.Handler.Simple
import           System.Log.Handler.Syslog
import           System.Log.Logger
import qualified Web.Scotty                          as S

type User       = String
type UserSocket = H.HashMap User Socket
type HostUser   = H.HashMap HostName User

-- | Server that accepts external connections
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

-- | Handle a single user, if the user is not whitelisted, closes the connection else
-- | close old connections and insert the new socket inside the hashmap
runConn :: (Socket, SockAddr) -> MVar UserSocket -> MVar HostUser -> IO ()
runConn (sock, (SockAddrInet _ host)) mus mhu = do
  hostUser <- readMVar mhu
  address  <- inet_ntoa host
  debugM "SimplePush" $ "Received new connetion from " ++ (show address)

  case H.lookup address hostUser of
    Just user -> modifyMVar_ mus $ \userSocket -> do
         closeOld user userSocket
         return $ H.insert user sock userSocket
    Nothing -> do 
      shutdown sock ShutdownBoth
      close sock

-- | Closes the old socket, if any, of the user
closeOld :: User -> UserSocket -> IO ()
closeOld user userSocket =
  when (H.member user userSocket) $ do
       let sock = fromJust $ H.lookup user userSocket
       connected <- isWritable sock
       when (connected) $ do
         shutdown sock ShutdownBoth
         close sock

-- | Serializes a message to be sent to the user prefixing the lenght, in bytes, of the
-- | message
serializeMessage :: ByteString -> ByteString
serializeMessage message = do
  let size = fromIntegral $ C.length message
  writeToByteString (writeInt32be size <> writeByteString message)

-- | Send a message to a user
sendPush :: ByteString -> Socket -> IO ()
sendPush message socket = do
  debugM "SimplePush" $ "Pushing: " ++ (show message)
  connected <- isWritable socket
  when connected (do
    let push = serializeMessage message
    void $ send socket push)

-- | Send the PING message every 10 minutes to all the active users to keep the
-- | connection alive
pingWorker :: MVar UserSocket -> IO ()
pingWorker mus = forever $ do
  sockets <- fmap H.elems (readMVar mus)
  mapM_ (sendPush "PING") sockets
  threadDelay (10 * 60 * 10^6) -- sleep 10 minutes

-- | Http API for enabling and pushing messages to users
httpServer :: MVar UserSocket -> MVar HostUser -> IO ()
httpServer mus mhu = S.scotty 9000 $ do
  S.post "/enable" (do
    userid <- S.param "user_id" :: S.ActionM String
    host   <- S.param "from"    :: S.ActionM HostName

    liftIO $ do
      debugM "SimplePush" $ "Enabling: " ++ (show userid)
      modifyMVar_ mhu $ \hostUser ->
        return $ H.insert host userid hostUser

      modifyMVar_ mus $ \userSocket -> do
        closeOld userid userSocket
        return $ H.delete userid userSocket)

  S.post "/push" (do
    userid  <- S.param "user_id"
    message <- S.param "message"

    liftIO $ modifyMVar_ mus $ \userSocket -> do
      let socket = H.lookup userid userSocket
      when (isJust socket) (sendPush message (fromJust socket))
      return userSocket)

setupLogger = do
  h <- streamHandler stderr DEBUG >>= \lh -> return $
    setFormatter lh (simpleLogFormatter "[$time : $loggername : $prio] $msg")
  updateGlobalLogger "SimplePush" $ do
    setLevel DEBUG
    addHandler h

main :: IO ()
main = do
  setupLogger
  mus <- newMVar H.empty
  mhu <- newMVar H.empty
  async $ httpServer mus mhu
  async $ pingWorker mus
  socketServer mus mhu
