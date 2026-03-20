module TutorialDB
    ( -- * Full column GADT
      AllCols (..)

      -- * Codecs and DB setup
    , withTempDB
    , withPersistentDB
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

      -- * Chain events (re-exported from MockChain)
    , MC.ChainEvent (..)
    , MC.BlockTree (..)
    , MC.dfs
    , MC.canonicalPath
    , MC.resolveCanonical
    , MC.wellFormed
    , MC.treeSlot

      -- * Constants
    , rollbackWindow
    ) where

import Audit (AuditCols (..))
import Balances (BalanceCols (..))
import ChainFollower.MockChain qualified as MC
import ChainFollower.Rollbacks.Types
    ( RollbackPoint
    )
import Composed
    ( ComposedInv
    , UnifiedCols (..)
    )
import Control.Lens (prism')
import Data.ByteString.Char8 qualified as BS8
import Data.Default (Default (..))
import Data.Type.Equality ((:~:) (..))
import Database.KV.Database
    ( KV
    , mkColumns
    )
import Database.KV.RocksDB (mkRocksDBDatabase)
import Database.KV.Transaction
    ( Codecs (..)
    , DSum (..)
    , GCompare (..)
    , GEq (..)
    , GOrdering (..)
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
import System.IO.Temp (withSystemTempDirectory)
import Text.Read (readMaybe)
import Types
    ( Block (..)
    , Transfer (..)
    )

-- * Column GADT

-- | Full column set: backend columns + rollback storage.
data AllCols c where
    InBackend :: UnifiedCols c -> AllCols c
    Rollbacks
        :: AllCols (KV Int (RollbackPoint ComposedInv Int))

instance GEq AllCols where
    geq (InBackend a) (InBackend b) = geq a b
    geq Rollbacks Rollbacks = Just Refl
    geq _ _ = Nothing

instance GCompare AllCols where
    gcompare (InBackend a) (InBackend b) =
        gcompare a b
    gcompare (InBackend _) Rollbacks = GLT
    gcompare Rollbacks (InBackend _) = GGT
    gcompare Rollbacks Rollbacks = GEQ

-- * Transaction runner

-- | Polymorphic transaction runner over AllCols.
type RunTx =
    forall a
     . Transaction IO ColumnFamily AllCols BatchOp a
    -> IO a

-- * DB setup

cfg :: Config
cfg = def{createIfMissing = True}

columnFamilyNames :: [(String, Config)]
columnFamilyNames =
    [ ("balances", cfg)
    , ("flags", cfg)
    , ("notes", cfg)
    , ("rollbacks", cfg)
    ]

allCodecs :: [DSum AllCols Codecs]
allCodecs =
    [ InBackend (InBalance BalanceKV)
        :=> Codecs
            (prism' BS8.pack (Just . BS8.unpack))
            ( prism'
                (BS8.pack . show)
                (readMaybe . BS8.unpack)
            )
    , InBackend (InAudit FlagKV)
        :=> Codecs
            (prism' BS8.pack (Just . BS8.unpack))
            (prism' BS8.pack (Just . BS8.unpack))
    , InBackend (InAudit NoteKV)
        :=> Codecs
            (prism' BS8.pack (Just . BS8.unpack))
            (prism' BS8.pack (Just . BS8.unpack))
    , Rollbacks
        :=> Codecs
            ( prism'
                (BS8.pack . show)
                (readMaybe . BS8.unpack)
            )
            ( prism'
                (BS8.pack . show)
                (readMaybe . BS8.unpack)
            )
    ]

mkRunTx :: DB -> RunTx
mkRunTx db =
    runTransactionUnguarded $
        mkRocksDBDatabase db $
            mkColumns
                (columnFamilies db)
                (fromPairList allCodecs)

-- | Run with a temporary DB (for tests).
withTempDB :: (RunTx -> IO a) -> IO a
withTempDB action =
    withSystemTempDirectory "chain-follower-test" $
        \dbPath ->
            withDBCF dbPath cfg columnFamilyNames $
                \db -> action (mkRunTx db)

-- | Run with a persistent DB at a given path.
withPersistentDB
    :: FilePath -> (RunTx -> IO a) -> IO a
withPersistentDB dbPath action =
    withDBCF dbPath cfg columnFamilyNames $
        \db -> action (mkRunTx db)

-- * Block generation

-- | Accounts in the simulation.
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

-- * State queries

-- | Query all account balances.
queryAllBalances
    :: RunTx -> IO [(String, Maybe Int)]
queryAllBalances runTx =
    runTx $
        mapM
            ( \a -> do
                b <-
                    mapColumns InBackend $
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
                    mapColumns InBackend $
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
                    mapColumns InBackend $
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

-- * Constants

-- | Number of slots of rollback history to keep.
rollbackWindow :: Int
rollbackWindow = 5
