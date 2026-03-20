module E2ESpec (spec) where

-- \| End-to-end tests covering the tutorial flow:
-- restoration, transition, following with inverses,
-- and rollback with state verification.

import ChainFollower.Backend
    ( Following (..)
    , Restoring (..)
    )
import Composed
    ( ComposedInv (..)
    , UnifiedCols
    , composedFollowing
    , composedRestoring
    )
import Control.Monad (foldM)
import Database.KV.Transaction (Transaction)
import Database.RocksDB (BatchOp, ColumnFamily)
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
    , queryAllBalances
    , queryAllFlags
    , snapshotState
    , withTestDB
    )
import Types (Block)

spec :: Spec
spec = describe "E2E" $ do
    describe "Restoration" $ do
        it "ingests blocks and updates balances" $
            withTestDB $ \runTx -> do
                -- Restore slot 1: bob -> carol 110
                _ <-
                    runTx $
                        restore composedRestoring (mkBlock 1)
                balances <- queryAllBalances runTx
                lookup "bob" balances
                    `shouldBe` Just (Just (-110))
                lookup "carol" balances
                    `shouldBe` Just (Just 110)

        it "flags large transfers during restoration" $
            withTestDB $ \runTx -> do
                -- Slot 3: dave -> eve 1500 (large)
                _ <-
                    foldM
                        (\r s -> runTx $ restore r (mkBlock s))
                        composedRestoring
                        [1 .. 3]
                flags <- queryAllFlags runTx
                lookup "dave" flags
                    `shouldSatisfy` \case
                        Just (Just _) -> True
                        _ -> False

    describe "Transition" $ do
        it "preserves state across phase transition" $
            withTestDB $ \runTx -> do
                finalRestoring <-
                    foldM
                        (\r s -> runTx $ restore r (mkBlock s))
                        composedRestoring
                        [1 .. 5]
                stateBefore <- snapshotState runTx
                _ <- toFollowing finalRestoring
                stateAfter <- snapshotState runTx
                stateAfter `shouldBe` stateBefore

    describe "Following" $ do
        it "produces inverse operations" $
            withTestDB $ \runTx -> do
                (inv, _) <-
                    runTx $
                        follow composedFollowing (mkBlock 1)
                balanceInvs inv `shouldSatisfy` (not . null)

        it "inverse restores exact previous state" $
            withTestDB $ \runTx -> do
                -- Follow one block, snapshot before and after
                stateBefore <- snapshotState runTx
                (inv, following') <-
                    runTx $
                        follow composedFollowing (mkBlock 1)
                stateAfter <- snapshotState runTx
                stateAfter `shouldSatisfy` (/= stateBefore)
                -- Apply inverse
                runTx $ applyInverse following' inv
                stateRestored <- snapshotState runTx
                stateRestored `shouldBe` stateBefore

    describe "Full lifecycle" $ do
        it "restore -> follow -> rollback restores state" $
            withTestDB $ \runTx -> do
                -- Phase 1: Restore 10 blocks
                finalRestoring <-
                    foldM
                        (\r s -> runTx $ restore r (mkBlock s))
                        composedRestoring
                        [1 .. 10]
                -- Phase 2: Transition
                following <- toFollowing finalRestoring
                stateAtSlot10 <- snapshotState runTx
                -- Phase 3: Follow 3 more blocks, collecting inverses
                (invs, finalFollowing) <-
                    foldThreeBlocks runTx following [11, 12, 13]
                stateAtSlot13 <- snapshotState runTx
                stateAtSlot13
                    `shouldSatisfy` (/= stateAtSlot10)
                -- Phase 4: Rollback all 3 (invs are most-recent-first)
                mapM_
                    (runTx . applyInverse finalFollowing . snd)
                    invs
                stateRolledBack <- snapshotState runTx
                stateRolledBack `shouldBe` stateAtSlot10

        it "partial rollback preserves intermediate state" $
            withTestDB $ \runTx -> do
                following <- toFollowing composedRestoring
                -- Follow 3 blocks
                (inv1, f1) <-
                    runTx $ follow following (mkBlock 1)
                stateAt1 <- snapshotState runTx
                (inv2, f2) <-
                    runTx $ follow f1 (mkBlock 2)
                (_inv3, f3) <-
                    runTx $ follow f2 (mkBlock 3)
                -- Undo only slot 3 and 2
                runTx $ applyInverse f3 _inv3
                runTx $ applyInverse f3 inv2
                stateAfterPartial <- snapshotState runTx
                stateAfterPartial `shouldBe` stateAt1
                -- Undo slot 1 too
                runTx $ applyInverse f3 inv1
                stateFinal <- snapshotState runTx
                -- Everything zeroed out (back to empty)
                let allZero =
                        all
                            (\(_, b) -> b == Nothing)
                            (snapBalances stateFinal)
                allZero `shouldBe` True

-- | Follow a list of slots, collecting (slot, inverse) pairs.
foldThreeBlocks
    :: RunTx
    -> Following
        IO
        ( Transaction
            IO
            ColumnFamily
            UnifiedCols
            BatchOp
        )
        Block
        ComposedInv
    -> [Int]
    -> IO
        ( [(Int, ComposedInv)]
        , Following
            IO
            ( Transaction
                IO
                ColumnFamily
                UnifiedCols
                BatchOp
            )
            Block
            ComposedInv
        )
foldThreeBlocks runTx f0 slots =
    foldM
        ( \(invs, f) s -> do
            (inv, f') <- runTx $ follow f (mkBlock s)
            pure ((s, inv) : invs, f')
        )
        ([], f0)
        slots
