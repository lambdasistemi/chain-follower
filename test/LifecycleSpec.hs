module LifecycleSpec (spec) where

import ChainFollower.Backend
    ( Init (..)
    , liftInit
    )
import ChainFollower.Rollbacks.Store qualified as Rollbacks
import ChainFollower.Runner
    ( Phase (..)
    , processBlock
    )
import Composed (ComposedInv, composedInit)
import Control.Monad (foldM, foldM_)
import Database.KV.Transaction
    ( Transaction
    , mapColumns
    )
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )
import TutorialDB
    ( AllCols (..)
    , mkBlock
    , rollbackWindow
    , snapshotState
    , withPersistentDB
    , withTempDB
    )
import Types (Block (..))

-- | The backend lifted into the full column type.
backend
    :: Init
        IO
        (Transaction IO cf AllCols op)
        Block
        ComposedInv
        Int
backend = liftInit (mapColumns InBackend) composedInit

spec :: Spec
spec = describe "Lifecycle" $ do
    describe "Fresh start" $ do
        it "restore then follow produces correct state" $
            withTempDB $ \runTx -> do
                -- Setup
                runTx $
                    Rollbacks.armageddonSetup
                        Rollbacks
                        0
                        Nothing
                restoring <- start backend
                -- Restore 10 blocks
                finalRestore <-
                    foldM
                        ( \phase slot ->
                            processBlock
                                False
                                runTx
                                Rollbacks
                                maxBound
                                slot
                                (mkBlock slot)
                                phase
                        )
                        (InRestoration restoring)
                        [1 .. 10]
                -- Transition to following
                let currentSlot = 10
                runTx $
                    Rollbacks.armageddonSetup
                        Rollbacks
                        currentSlot
                        Nothing
                following <- start backend
                -- Follow 5 more blocks
                foldM_
                    ( \phase slot ->
                        processBlock
                            True
                            runTx
                            Rollbacks
                            rollbackWindow
                            slot
                            (mkBlock slot)
                            phase
                    )
                    (InRestoration following)
                    [11 .. 15]
                -- Verify state matches restoring all 15
                actual <- snapshotState runTx
                expected <- withTempDB $ \runTx2 -> do
                    runTx2 $
                        Rollbacks.armageddonSetup
                            Rollbacks
                            0
                            Nothing
                    restoring2 <- start backend
                    foldM_
                        ( \phase slot ->
                            processBlock
                                False
                                runTx2
                                Rollbacks
                                maxBound
                                slot
                                (mkBlock slot)
                                phase
                        )
                        (InRestoration restoring2)
                        [1 .. 15]
                    snapshotState runTx2
                actual `shouldBe` expected
                -- Suppress unused warning
                let _ = finalRestore
                pure ()

    describe "Phase equivalence" $ do
        it "restoring N blocks matches following N blocks" $
            do
                let blocks = map mkBlock [1 .. 10]
                stateA <- withTempDB $ \runTx -> do
                    runTx $
                        Rollbacks.armageddonSetup
                            Rollbacks
                            0
                            Nothing
                    restoring <- start backend
                    foldM_
                        ( \phase block ->
                            processBlock
                                True
                                runTx
                                Rollbacks
                                rollbackWindow
                                (blockSlot block)
                                block
                                phase
                        )
                        (InRestoration restoring)
                        blocks
                    snapshotState runTx
                stateB <- withTempDB $ \runTx -> do
                    runTx $
                        Rollbacks.armageddonSetup
                            Rollbacks
                            0
                            Nothing
                    following <- start backend
                    foldM_
                        ( \phase block ->
                            processBlock
                                True
                                runTx
                                Rollbacks
                                rollbackWindow
                                (blockSlot block)
                                block
                                phase
                        )
                        (InRestoration following)
                        blocks
                    snapshotState runTx
                stateA `shouldBe` stateB

    describe "Persistence across reopens" $ do
        it "state survives close and reopen" $
            withSystemTempDirectory "chain-follower-persist" $
                \tmpDir -> do
                    let dbPath = tmpDir ++ "/db"
                    -- Session 1: follow some blocks
                    stateAfterFollow <-
                        withPersistentDB dbPath $ \runTx -> do
                            runTx $
                                Rollbacks.armageddonSetup
                                    Rollbacks
                                    0
                                    Nothing
                            following <-
                                start backend
                            foldM_
                                ( \phase slot ->
                                    processBlock
                                        True
                                        runTx
                                        Rollbacks
                                        rollbackWindow
                                        slot
                                        (mkBlock slot)
                                        phase
                                )
                                (InRestoration following)
                                [1 .. 5]
                            snapshotState runTx
                    -- Session 2: reopen and verify
                    stateAfterReopen <-
                        withPersistentDB dbPath $ \runTx -> do
                            mTip <-
                                runTx $
                                    Rollbacks.queryTip Rollbacks
                            mTip `shouldBe` Just 5
                            snapshotState runTx
                    stateAfterReopen `shouldBe` stateAfterFollow
