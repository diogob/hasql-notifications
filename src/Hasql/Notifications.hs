{-| This module encapsulates knowledge about the SQL commands and the Hasql interface.
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
import Control.Concurrent (threadWaitRead)
import Control.Exception (Exception, throw)

-- | A wrapped bytestring that represents a properly escaped and quoted PostgreSQL identifier
newtype PgIdentifier = PgIdentifier ByteString deriving (Show)

-- | Uncatchable exceptions thrown and never caught.
newtype FatalError = FatalError { fatalErrorMessage :: String }
  deriving (Show)

instance Exception FatalError

-- | Given a PgIdentifier returns the wrapped bytestring
fromPgIdentifier :: PgIdentifier -> ByteString
fromPgIdentifier (PgIdentifier bs) = bs

-- | Given a bytestring returns a properly quoted and escaped PgIdentifier
toPgIdentifier :: Text -> PgIdentifier
toPgIdentifier x =
  PgIdentifier $ "\"" <> T.encodeUtf8 (strictlyReplaceQuotes x) <> "\""
  where
    strictlyReplaceQuotes :: Text -> Text
    strictlyReplaceQuotes = T.replace "\"" ("\"\"" :: Text)

-- | Given a Hasql Pool, a channel and a message sends a notify command to the database
notifyPool :: Pool -> Text -> Text -> IO (Either UsageError ())
notifyPool pool channel mesg =
   use pool (statement (channel, mesg) callStatement)
   where
     callStatement = HST.Statement ("SELECT pg_notify" <> "($1, $2)") encoder HD.noResult False
     encoder = contramap fst (HE.param $ HE.nonNullable HE.text) <> contramap snd (HE.param $ HE.nonNullable HE.text)

-- | Given a Hasql Connection, a channel and a message sends a notify command to the database
notify :: Connection -> PgIdentifier -> Text -> IO (Either S.QueryError ())
notify con channel mesg =
   run (sql ("NOTIFY " <> fromPgIdentifier channel <> ", '" <> T.encodeUtf8 mesg <> "'")) con

-- | Given a Hasql Connection and a channel sends a listen command to the database
listen :: Connection -> PgIdentifier -> IO ()
listen con channel =
  void $ withLibPQConnection con execListen
  where
    execListen pqCon = void $ PQ.exec pqCon $ "LISTEN " <> fromPgIdentifier channel

-- | Given a Hasql Connection and a channel sends a unlisten command to the database
unlisten :: Connection -> PgIdentifier -> IO ()
unlisten con channel =
  void $ withLibPQConnection con execListen
  where
    execListen pqCon = void $ PQ.exec pqCon $ "UNLISTEN " <> fromPgIdentifier channel


{- | Given a function that handles notifications and a Hasql connection forks a thread that listens on the database connection and calls the handler everytime a message arrives.

   The message handler passed as first argument needs two parameters channel and payload.
-}

waitForNotifications :: (ByteString -> ByteString -> IO()) -> Connection -> IO ()
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
            Just fd -> do
              void $ threadWaitRead fd
              void $ PQ.consumeInput pqCon
        Just notification ->
           sendNotification (PQ.notifyRelname notification) (PQ.notifyExtra notification)
    panic :: String -> a
    panic a = throw (FatalError a)
