{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings, ViewPatterns #-}
module Main where

import           Blaze.ByteString.Builder
import           Blaze.ByteString.Builder.ByteString
import           Blaze.ByteString.Builder.Int
import           Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.TVar
import           Control.Concurrent.Async
import           Control.Concurrent.MVar
import Control.Exception
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
import GHC.Conc.Sync (unsafeIOToSTM)

type User       = String
type UserSocket = H.HashMap User Handle
type HostUser   = H.HashMap HostName User

data ServerState = ServerState {
     ssWhitelist :: TVar (H.HashMap HostName User)
,    ssHandles   :: TVar (H.HashMap User Handle)
}

-- | Server that accepts external connections
socketServer :: ServerState -> IO ()
socketServer state = do
  sock <- socket AF_INET Stream 0
  setSocketOption sock ReuseAddr 1
--  setSocketOption sock KeepAlive 1
  bindSocket sock (SockAddrInet 8888 iNADDR_ANY)
  listen sock 2
  forever $ do
    (sock, (SockAddrInet _ host)) <- accept sock
    handle <- socketToHandle sock WriteMode
    hSetBuffering handle NoBuffering
    forkIO (runConn handle host state)

-- | Handle a single user, if the user is not whitelisted, closes the connection else
-- | close old connections and insert the new socket inside the hashmap
runConn :: Handle -> HostAddress -> ServerState -> IO ()
runConn handle host ServerState{..} = do
  hostUser <- atomically $ readTVar ssWhitelist
  address  <- inet_ntoa host
  debugM "SimplePush" $ "Received new connetion from " ++ (show address)

  case H.lookup address hostUser of
    Just user -> atomically $ do
      userHandle <- readTVar ssHandles
      closeOld user userHandle
      writeTVar ssHandles $ H.insert user handle userHandle
    Nothing -> return ()

closeOld user userHandle =
  case H.lookup user userHandle of
    Just handle -> unsafeIOToSTM (hClose handle)
    Nothing     -> return ()

-- | Serializes a message to be sent to the user prefixing the lenght, in bytes, of the
-- | message
serializeMessage :: ByteString -> ByteString
serializeMessage message = do
  let size = fromIntegral $ C.length message
  writeToByteString (writeInt32be size <> writeByteString message)

-- | Send a message to a user
sendPush :: ByteString -> Handle -> IO ()
sendPush message handle = do
  debugM "SimplePush" $ "Pushing: " ++ (show message)
  let push = serializeMessage message
  catch (C.hPutStr handle push) (\(e :: IOError) -> hClose handle)

-- | Send the PING message every 10 minutes to all the active users to keep the
-- | connection alive
pingWorker :: ServerState -> IO ()
pingWorker ServerState{..} = forever $ do
  handles <- fmap H.elems (atomically $ readTVar ssHandles)
  mapM_ (sendPush "PING") handles
  threadDelay (10 * 60 * 10^6) -- sleep 10 minutes

-- | Http API for enabling and pushing messages to users
httpServer :: ServerState -> IO ()
httpServer ServerState{..} = S.scotty 9000 $ do
  S.post "/enable" $ do
    userid <- S.param "user_id" :: S.ActionM String
    host   <- S.param "from"    :: S.ActionM HostName

    liftIO $ do
      debugM "SimplePush" $ "Enabling: " ++ (show userid)
      atomically $ do
        hostUser <- readTVar ssWhitelist
        writeTVar ssWhitelist $ H.insert host userid hostUser

        userSocket <- readTVar ssHandles
        closeOld userid userSocket
        writeTVar ssHandles $ H.delete userid userSocket

  S.post "/push" $ do
    userid  <- S.param "user_id"
    message <- S.param "message"

    ok <- liftIO $ atomically $ do
         userSocket <- readTVar ssHandles
         return $ H.lookup userid userSocket

    case ok of
      Just handle  -> liftIO $ sendPush message handle
      Nothing      -> return ()

setupLogger = do
  h <- streamHandler stderr DEBUG >>= \lh -> return $
    setFormatter lh (simpleLogFormatter "[$time : $loggername : $prio] $msg")
  updateGlobalLogger "SimplePush" $ do
    setLevel DEBUG
    addHandler h

main :: IO ()
main = do
  setupLogger
  mus <- newTVarIO H.empty
  mhu <- newTVarIO H.empty
  let state = ServerState mhu mus
  async $ httpServer state
  async $ pingWorker state
  socketServer state
