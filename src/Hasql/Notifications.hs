{-# LANGUAGE CPP #-}
{-|
  This module has functions to send commands LISTEN and NOTIFY to the database server.
  It also has a function to wait for and handle notifications on a database connection.

  For more information check the [PostgreSQL documentation](https://www.postgresql.org/docs/current/libpq-notify.html).

-}
module Hasql.Notifications
  ( notifyPool
  , notify
  , listen
  , unlisten
  , waitForNotifications
  , PgIdentifier
  , toPgIdentifier
  , fromPgIdentifier
  ) where

import Hasql.Pool (Pool, UsageError, use)
import Hasql.Session (sql, run, statement)
import qualified Hasql.Session as S
import qualified Hasql.Statement as HST
import Hasql.Connection (Connection, withLibPQConnection)
import qualified Hasql.Decoders as HD
import qualified Hasql.Encoders as HE
import qualified Database.PostgreSQL.LibPQ as PQ
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.ByteString.Char8 (ByteString)
import Data.Functor.Contravariant (contramap)
import Control.Monad (void, forever)
#if defined(mingw32_HOST_OS)
import           Control.Concurrent ( threadDelay )
#else
import Control.Concurrent (threadWaitRead)
#endif
import Control.Exception (Exception, throw)

-- | A wrapped text that represents a properly escaped and quoted PostgreSQL identifier
newtype PgIdentifier = PgIdentifier Text deriving (Show)

-- | Uncatchable exceptions thrown and never caught.
newtype FatalError = FatalError { fatalErrorMessage :: String }
  deriving (Show)

instance Exception FatalError

-- | Given a PgIdentifier returns the wrapped text
fromPgIdentifier :: PgIdentifier -> Text
fromPgIdentifier (PgIdentifier bs) = bs

-- | Given a text returns a properly quoted and escaped PgIdentifier
toPgIdentifier :: Text -> PgIdentifier
toPgIdentifier x =
  PgIdentifier $ "\"" <> strictlyReplaceQuotes x <> "\""
  where
    strictlyReplaceQuotes :: Text -> Text
    strictlyReplaceQuotes = T.replace "\"" ("\"\"" :: Text)

-- | Given a Hasql Pool, a channel and a message sends a notify command to the database
notifyPool :: Pool -- ^ Pool from which the connection will be used to issue a NOTIFY command.
           -> Text -- ^ Channel where to send the notification
           -> Text -- ^ Payload to be sent with the notification
           -> IO (Either UsageError ())
notifyPool pool channel mesg =
   use pool (statement (channel, mesg) callStatement)
   where
     callStatement = HST.Statement ("SELECT pg_notify" <> "($1, $2)") encoder HD.noResult False
     encoder = contramap fst (HE.param $ HE.nonNullable HE.text) <> contramap snd (HE.param $ HE.nonNullable HE.text)

-- | Given a Hasql Connection, a channel and a message sends a notify command to the database
notify :: Connection -- ^ Connection to be used to send the NOTIFY command
       -> PgIdentifier -- ^ Channel where to send the notification
       -> Text -- ^ Payload to be sent with the notification
       -> IO (Either S.QueryError ())
notify con channel mesg =
   run (sql $ T.encodeUtf8 ("NOTIFY " <> fromPgIdentifier channel <> ", '" <> mesg <> "'")) con

{-| 
  Given a Hasql Connection and a channel sends a listen command to the database.
  Once the connection sends the LISTEN command the server register its interest in the channel.
  Hence it's important to keep track of which connection was used to open the listen command.

  Example of listening and waiting for a notification:

  @
  import System.Exit (die)

  import Hasql.Connection
  import Hasql.Notifications

  main :: IO ()
  main = do
    dbOrError <- acquire "postgres://localhost/db_name"
    case dbOrError of
        Right db -> do
            let channelToListen = toPgIdentifier "sample-channel"
            listen db channelToListen
            waitForNotifications (\channel _ -> print $ "Just got notification on channel " <> channel) db
        _ -> die "Could not open database connection"
  @
-}
listen :: Connection -- ^ Connection to be used to send the LISTEN command
       -> PgIdentifier -- ^ Channel this connection will be registered to listen to
       -> IO ()
listen con channel =
  void $ withLibPQConnection con execListen
  where
    execListen pqCon = void $ PQ.exec pqCon $ T.encodeUtf8 $ "LISTEN " <> fromPgIdentifier channel

-- | Given a Hasql Connection and a channel sends a unlisten command to the database
unlisten :: Connection -- ^ Connection currently registerd by a previous 'listen' call
         -> PgIdentifier -- ^ Channel this connection will be deregistered from
         -> IO ()
unlisten con channel =
  void $ withLibPQConnection con execListen
  where
    execListen pqCon = void $ PQ.exec pqCon $ T.encodeUtf8 $ "UNLISTEN " <> fromPgIdentifier channel


{-| 
  Given a function that handles notifications and a Hasql connection it will listen 
  on the database connection and call the handler everytime a message arrives.

  The message handler passed as first argument needs two parameters channel and payload.
  See an example of handling notification on a separate thread:

  @
  import Control.Concurrent.Async (async)
  import Control.Monad (void)
  import System.Exit (die)

  import Hasql.Connection
  import Hasql.Notifications

  notificationHandler :: ByteString -> ByteString -> IO()
  notificationHandler channel payload = 
    void $ async do
      print $ "Handle payload " <> payload <> " in its own thread"

  main :: IO ()
  main = do
    dbOrError <- acquire "postgres://localhost/db_name"
    case dbOrError of
        Right db -> do
            let channelToListen = toPgIdentifier "sample-channel"
            listen db channelToListen
            waitForNotifications notificationHandler db
        _ -> die "Could not open database connection"
  @
-}

waitForNotifications :: (ByteString -> ByteString -> IO()) -- ^ Callback function to handle incoming notifications
                     -> Connection -- ^ Connection where we will listen to
                     -> IO ()
waitForNotifications sendNotification con =
  withLibPQConnection con $ void . forever . pqFetch
  where
    pqFetch pqCon = do
      mNotification <- PQ.notifies pqCon
      case mNotification of
        Nothing -> do
          mfd <- PQ.socket pqCon
          case mfd of
            Nothing  -> panic "Error checking for PostgreSQL notifications"
#if defined(mingw32_HOST_OS)
            Just _ -> do
              void $ threadDelay 1000000
#else
            Just fd -> do
              void $ threadWaitRead fd
#endif
              void $ PQ.consumeInput pqCon
        Just notification ->
           sendNotification (PQ.notifyRelname notification) (PQ.notifyExtra notification)
    panic :: String -> a
    panic a = throw (FatalError a)
