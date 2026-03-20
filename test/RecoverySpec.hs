module RecoverySpec (spec) where

-- \| Integration tests: crash recovery and persistence.
-- Verifies that state survives DB close/reopen and
-- that partial operations don't corrupt state.

import Audit (AuditCols (..))
import Balances (BalanceCols (..))
import ChainFollower.Backend
    ( Following (..)
    , Restoring (..)
    )
import Composed
    ( UnifiedCols (..)
    , composedFollowing
    , composedRestoring
    )
import Control.Exception qualified
import Control.Lens (prism')
import Control.Monad (foldM)
import Data.ByteString.Char8 qualified as BS8
import Data.Default (Default (..))
import Database.KV.Database (mkColumns)
import Database.KV.RocksDB (mkRocksDBDatabase)
import Database.KV.Transaction
    ( Codecs (..)
    , DSum (..)
    , fromPairList
    , runTransactionUnguarded
    )
import Database.RocksDB
    ( Config (createIfMissing)
    , DB (..)
    , withDBCF
    )
import System.Directory qualified
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )
import TestDB
    ( RunTx
    , StateSnapshot (..)
    , mkBlock
    , snapshotState
    )
import Text.Read (readMaybe)

cfg :: Config
cfg = def{createIfMissing = True}

-- | Open DB at a given path with the standard codecs.
openDB
    :: FilePath -> (RunTx -> IO a) -> IO a
openDB dbPath action =
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

spec :: Spec
spec = describe "Recovery" $ do
    describe "Persistence" $ do
        it "state survives DB close and reopen" $ do
            -- Use a fixed temp dir so we can reopen
            let dbPath = "/tmp/chain-follower-recovery-test"
            -- Clean up from previous runs
            _ <- try_ $ removeDirectoryRecursive dbPath
            -- Session 1: restore some blocks
            stateAfterRestore <-
                openDB dbPath $ \runTx -> do
                    _ <-
                        foldM
                            (\r s -> runTx $ restore r (mkBlock s))
                            composedRestoring
                            [1 .. 5]
                    snapshotState runTx
            -- Session 2: reopen and verify
            stateAfterReopen <-
                openDB dbPath $ \runTx ->
                    snapshotState runTx
            stateAfterReopen `shouldBe` stateAfterRestore
            -- Cleanup
            _ <- try_ $ removeDirectoryRecursive dbPath
            pure ()

        it "following state survives reopen" $ do
            let dbPath = "/tmp/chain-follower-recovery-test-2"
            _ <- try_ $ removeDirectoryRecursive dbPath
            -- Session 1: follow blocks
            stateAfterFollow <-
                openDB dbPath $ \runTx -> do
                    _ <-
                        foldM
                            ( \f b -> do
                                (_, f') <-
                                    runTx $ follow f b
                                pure f'
                            )
                            composedFollowing
                            (map mkBlock [1 .. 5])
                    snapshotState runTx
            -- Session 2: reopen
            stateAfterReopen <-
                openDB dbPath $ \runTx ->
                    snapshotState runTx
            stateAfterReopen `shouldBe` stateAfterFollow
            _ <- try_ $ removeDirectoryRecursive dbPath
            pure ()

    describe "Restart recovery" $ do
        it "can resume restoration after restart" $ do
            let dbPath = "/tmp/chain-follower-recovery-test-3"
            _ <- try_ $ removeDirectoryRecursive dbPath
            -- Session 1: restore blocks 1..5
            openDB dbPath $ \runTx ->
                foldM
                    (\r s -> runTx $ restore r (mkBlock s))
                    composedRestoring
                    [1 .. 5]
                    >> pure ()
            -- Session 2: restore blocks 6..10 (fresh restoring, same DB)
            openDB dbPath $ \runTx ->
                foldM
                    (\r s -> runTx $ restore r (mkBlock s))
                    composedRestoring
                    [6 .. 10]
                    >> pure ()
            -- The DB now has the combined effect of
            -- blocks 1..5 (from session 1) with blocks
            -- 6..10 overlaid (from session 2's fresh restoring).
            -- The important thing is it doesn't crash.
            stateAfter <-
                openDB dbPath $ \runTx ->
                    snapshotState runTx
            -- State should have data (not all empty)
            snapBalances stateAfter
                `shouldSatisfy` any (\(_, b) -> b /= Nothing)
            _ <- try_ $ removeDirectoryRecursive dbPath
            pure ()

        it "rollback after restart works on persisted state" $ do
            let dbPath = "/tmp/chain-follower-recovery-test-4"
            _ <- try_ $ removeDirectoryRecursive dbPath
            -- Session 1: follow block 1, capture inverse and state
            (inv, stateBefore) <-
                openDB dbPath $ \runTx -> do
                    s <- snapshotState runTx
                    (inv, _) <-
                        runTx $
                            follow composedFollowing (mkBlock 1)
                    pure (inv, s)
            -- Session 2: reopen and apply inverse
            stateAfterRollback <-
                openDB dbPath $ \runTx -> do
                    runTx $
                        applyInverse composedFollowing inv
                    snapshotState runTx
            stateAfterRollback `shouldBe` stateBefore
            _ <- try_ $ removeDirectoryRecursive dbPath
            pure ()

-- | Helpers
removeDirectoryRecursive :: FilePath -> IO ()
removeDirectoryRecursive path = do
    System.Directory.removeDirectoryRecursive path

try_ :: IO a -> IO (Either IOError a)
try_ = Control.Exception.try
