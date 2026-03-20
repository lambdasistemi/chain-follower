module TestDB
    ( -- * DB setup
      withTestDB
    , RunTx

      -- * Block generation
    , mkBlock
    , accounts

      -- * State queries
    , queryAllBalances
    , queryAllFlags
    , queryAllNotes
    , StateSnapshot (..)
    , snapshotState
    ) where

-- \| Shared test infrastructure: RocksDB setup, block
-- generation, and state query helpers.

import Audit (AuditCols (..))
import Balances (BalanceCols (..))
import Composed (UnifiedCols (..))
import Control.Lens (prism')
import Data.ByteString.Char8 qualified as BS8
import Data.Default (Default (..))
import Database.KV.Database (mkColumns)
import Database.KV.RocksDB (mkRocksDBDatabase)
import Database.KV.Transaction
    ( Codecs (..)
    , DSum (..)
    , Transaction
    , fromPairList
    , mapColumns
    , query
    , runTransactionUnguarded
    )
import Database.RocksDB
    ( BatchOp
    , ColumnFamily
    , Config (createIfMissing)
    , DB (..)
    , withDBCF
    )
import System.IO.Temp
    ( withSystemTempDirectory
    )
import Text.Read (readMaybe)
import Types
    ( Block (..)
    , Transfer (..)
    )

-- | Polymorphic transaction runner.
type RunTx =
    forall a
     . Transaction
        IO
        ColumnFamily
        UnifiedCols
        BatchOp
        a
    -> IO a

-- | Accounts used in tests.
accounts :: [String]
accounts =
    ["alice", "bob", "carol", "dave", "eve"]

-- | Generate a deterministic block for a given slot.
mkBlock :: Int -> Block
mkBlock slot =
    Block
        { blockSlot = slot
        , blockTransfers = transfers
        }
  where
    n = length accounts
    sender = accounts !! (slot `mod` n)
    receiver = accounts !! ((slot + 1) `mod` n)
    amount
        | slot `mod` 3 == 0 = 1500
        | otherwise = 100 + slot * 10
    transfers = [Transfer sender receiver amount]

cfg :: Config
cfg = def{createIfMissing = True}

-- | Run an action with a fresh RocksDB and transaction runner.
withTestDB :: (RunTx -> IO a) -> IO a
withTestDB action =
    withSystemTempDirectory "chain-follower-test" $
        \dbPath ->
            withDBCF
                dbPath
                cfg
                [ ("balances", cfg)
                , ("flags", cfg)
                , ("notes", cfg)
                ]
                $ \db -> do
                    let codecs =
                            fromPairList
                                [ InBalance BalanceKV
                                    :=> Codecs
                                        ( prism'
                                            BS8.pack
                                            (Just . BS8.unpack)
                                        )
                                        ( prism'
                                            (BS8.pack . show)
                                            (readMaybe . BS8.unpack)
                                        )
                                , InAudit FlagKV
                                    :=> Codecs
                                        ( prism'
                                            BS8.pack
                                            (Just . BS8.unpack)
                                        )
                                        ( prism'
                                            BS8.pack
                                            (Just . BS8.unpack)
                                        )
                                , InAudit NoteKV
                                    :=> Codecs
                                        ( prism'
                                            BS8.pack
                                            (Just . BS8.unpack)
                                        )
                                        ( prism'
                                            BS8.pack
                                            (Just . BS8.unpack)
                                        )
                                ]
                        database =
                            mkRocksDBDatabase db $
                                mkColumns
                                    (columnFamilies db)
                                    codecs
                        runTx
                            :: RunTx
                        runTx =
                            runTransactionUnguarded database
                    action runTx

-- | Query all account balances.
queryAllBalances
    :: RunTx -> IO [(String, Maybe Int)]
queryAllBalances runTx =
    runTx $
        mapM
            ( \a -> do
                b <-
                    mapColumns InBalance $
                        query BalanceKV a
                pure (a, b)
            )
            accounts

-- | Query all audit flags.
queryAllFlags
    :: RunTx -> IO [(String, Maybe String)]
queryAllFlags runTx =
    runTx $
        mapM
            ( \a -> do
                f <-
                    mapColumns InAudit $
                        query FlagKV a
                pure (a, f)
            )
            accounts

-- | Query all audit notes.
queryAllNotes
    :: RunTx -> IO [(String, Maybe String)]
queryAllNotes runTx =
    runTx $
        mapM
            ( \a -> do
                n <-
                    mapColumns InAudit $
                        query NoteKV a
                pure (a, n)
            )
            accounts

-- | Full state snapshot for comparison.
data StateSnapshot = StateSnapshot
    { snapBalances :: [(String, Maybe Int)]
    , snapFlags :: [(String, Maybe String)]
    , snapNotes :: [(String, Maybe String)]
    }
    deriving stock (Show, Eq)

-- | Capture the full state.
snapshotState :: RunTx -> IO StateSnapshot
snapshotState runTx =
    StateSnapshot
        <$> queryAllBalances runTx
        <*> queryAllFlags runTx
        <*> queryAllNotes runTx
