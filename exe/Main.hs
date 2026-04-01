module Main (main) where

import ChainFollower.Backend
    ( Following
    , Init (..)
    , liftInit
    )
import ChainFollower.Rollbacks.Store qualified as Rollbacks
import ChainFollower.Runner
    ( Phase (..)
    , processBlock
    , rollbackTo
    )
import Composed (ComposedInv, composedInit)
import Control.Monad (forM_, unless, when)
import Control.Tracer (nullTracer)
import Data.ByteString (ByteString)
import Database.KV.Transaction
    ( Transaction
    , mapColumns
    )
import TutorialDB
    ( AllCols (..)
    , ChainEvent (..)
    , RunTx
    , StateSnapshot (..)
    , mkBlock
    , resolveCanonical
    , rollbackWindow
    , snapshotState
    , withTempDB
    )
import Types (Block)

-- * Helpers

-- | Print a state snapshot in a compact format.
printSnapshot :: String -> StateSnapshot -> IO ()
printSnapshot label StateSnapshot{snapBalances, snapFlags, snapNotes} =
    do
        putStrLn $ "  [" ++ label ++ "]"
        putStr "    balances:"
        forM_ snapBalances $ \(name, mBal) ->
            putStr $
                " "
                    ++ name
                    ++ "="
                    ++ maybe "0" show mBal
        putStrLn ""
        let activeFlags =
                [(n, f) | (n, Just f) <- snapFlags]
        unless (null activeFlags) $ do
            putStr "    flags:   "
            forM_ activeFlags $ \(n, f) ->
                putStr $
                    " " ++ n ++ "=\"" ++ f ++ "\""
            putStrLn ""
        let activeNotes =
                [(n, v) | (n, Just v) <- snapNotes]
        unless (null activeNotes) $ do
            putStr "    notes:   "
            forM_ activeNotes $ \(n, v) ->
                putStr $
                    " " ++ n ++ "=\"" ++ v ++ "\""
            putStrLn ""

-- | Print a section header.
section :: String -> IO ()
section title = do
    putStrLn ""
    putStrLn $ "  === " ++ title ++ " ==="
    putStrLn ""

-- | The lifted backend Init over AllCols.
backend
    :: Init
        IO
        (Transaction IO cf AllCols op)
        Block
        ComposedInv
        Int
backend =
    liftInit (mapColumns InBackend) composedInit

-- * Main

main :: IO ()
main = do
    putStrLn ""
    putStrLn "  Chain Follower Lifecycle Tutorial"
    putStrLn "  ================================="
    putStrLn ""
    putStrLn
        "  This tutorial demonstrates the full"
    putStrLn
        "  lifecycle of a chain follower: restoration,"
    putStrLn
        "  following, rollback, and restart."

    -- Phases 1-5 run in one temporary database.
    stateAfterPhase5 <- withTempDB $ \runTx -> do
        -- ── Phase 1: Fresh start ────────────────
        section "Phase 1: Fresh Start (Restoration)"
        putStrLn
            "  No rollback tip — fresh database."
        putStrLn
            "  Call Init.start for bulk"
        putStrLn
            "  ingestion with no inverse tracking."

        mTip <-
            runTx $ Rollbacks.queryTip Rollbacks
        putStrLn $
            "  Rollback tip: " ++ show mTip

        r <- start backend
        let phase0 = InRestoration r

        putStrLn ""
        putStrLn
            "  Restoring blocks 1..15 (no inverses):"
        _ <-
            foldPhase
                runTx
                False
                phase0
                [1 .. 15]
                ( \slot ->
                    when (slot `mod` 5 == 0) $ do
                        snap <- snapshotState runTx
                        printSnapshot
                            ("after slot " ++ show slot)
                            snap
                )

        -- ── Phase 2: Transition ─────────────────
        section "Phase 2: Transition to Following"
        putStrLn
            "  Near the chain tip. Set up rollback"
        putStrLn
            "  sentinel and process with atTip=True."
        putStrLn
            "  Every block now stores inverses."

        runTx $
            Rollbacks.armageddonSetup
                Rollbacks
                15
                Nothing
        r2 <- start backend
        let phase2start = InRestoration r2

        putStrLn ""
        putStrLn
            "  Following blocks 16..20 (with inverses):"
        phase2 <-
            foldPhase
                runTx
                True
                phase2start
                [16 .. 20]
                ( \slot -> do
                    snap <- snapshotState runTx
                    printSnapshot
                        ("after slot " ++ show slot)
                        snap
                )

        -- ── Phase 3: Fork (rollback) ────────────
        section "Phase 3: Simulate a Fork (Rollback)"
        putStrLn
            "  Chain source says: fork! Roll back to"
        putStrLn
            "  slot 18. Blocks 19-20 are undone by"
        putStrLn
            "  applying stored inverses in reverse."

        (n3, following3) <- extractFollowing phase2
        (result, _) <-
            runTx $
                rollbackTo Rollbacks following3 n3 18
        putStrLn $
            "  rollbackTo 18 => " ++ show result

        snap3 <- snapshotState runTx
        printSnapshot "after rollback to 18" snap3

        -- ── Phase 4: Follow the fork ────────────
        section "Phase 4: Follow the Forked Chain"
        putStrLn
            "  New blocks 19'..22 on the forked chain."
        putStrLn
            "  (mkBlock is deterministic, so same content"
        putStrLn
            "  — in a real chain these would differ.)"

        r4 <- start backend
        phase4 <-
            foldPhase
                runTx
                True
                (InRestoration r4)
                [19 .. 22]
                ( \slot ->
                    when (slot == 22) $ do
                        snap <- snapshotState runTx
                        printSnapshot
                            ("after slot " ++ show slot)
                            snap
                )

        _ <- extractFollowing phase4
        section "Phase 5: Offline Restart (Small Gap)"
        putStrLn
            "  You were at slot 22. Blockchain is now"
        putStrLn
            "  at slot 25. Gap=3 <= rollbackWindow=5."
        putStrLn
            "  Stay in FOLLOWING mode, catch up."

        -- ── Phase 5: Small-gap restart ──────────
        r5 <- start backend
        phase5 <-
            foldPhase
                runTx
                True
                (InRestoration r5)
                [23 .. 25]
                ( \slot ->
                    when (slot == 25) $ do
                        snap <- snapshotState runTx
                        printSnapshot
                            ("after slot " ++ show slot)
                            snap
                )

        _ <- extractFollowing phase5
        snapshotState runTx

    -- ── Phase 6: Large-gap restart ──────────────
    -- This runs in a FRESH database, simulating a
    -- full armageddon wipe + re-restore.
    finalState <- withTempDB $ \runTx -> do
        section "Phase 6: Offline Restart (Large Gap)"
        putStrLn
            "  You were at slot 25. Blockchain is now"
        putStrLn
            "  at slot 40. Gap=15 > rollbackWindow=5."
        putStrLn
            "  Rollback history is insufficient."
        putStrLn
            "  Need armageddon: wipe everything and"
        putStrLn
            "  re-restore the full canonical chain."

        putStrLn ""
        putStrLn "  Running armageddonCleanup loop..."
        let cleanupLoop = do
                more <-
                    runTx $
                        Rollbacks.armageddonCleanup
                            Rollbacks
                            100
                when more cleanupLoop
        cleanupLoop
        putStrLn "  Cleanup complete."

        putStrLn
            "  Running armageddonSetup at slot 0..."
        runTx $
            Rollbacks.armageddonSetup
                Rollbacks
                0
                Nothing

        putStrLn ""
        putStrLn "  Re-restoring canonical chain 1..35:"
        r6 <- start backend
        _ <-
            foldPhase
                runTx
                False
                (InRestoration r6)
                [1 .. 35]
                ( \slot ->
                    when
                        ( slot `mod` 10 == 0
                            || slot == 35
                        )
                        $ do
                            snap <- snapshotState runTx
                            printSnapshot
                                ( "after slot "
                                    ++ show slot
                                )
                                snap
                )

        putStrLn ""
        putStrLn
            "  Transition to following at slot 35..."
        runTx $
            Rollbacks.armageddonSetup
                Rollbacks
                35
                Nothing
        r6f <- start backend

        putStrLn "  Following blocks 36..40:"
        phase6final <-
            foldPhase
                runTx
                True
                (InRestoration r6f)
                [36 .. 40]
                ( \slot ->
                    when (slot == 40) $ do
                        snap <- snapshotState runTx
                        printSnapshot
                            ("after slot " ++ show slot)
                            snap
                )

        _ <- extractFollowing phase6final
        snapshotState runTx

    -- ── Phase 7: Verification ───────────────────
    section "Phase 7: Verification"
    putStrLn
        "  Verify: the final state after armageddon"
    putStrLn
        "  + re-restore equals a clean single-pass"
    putStrLn
        "  of the canonical chain."

    let canonicalEvents =
            map (\s -> Forward s (mkBlock s)) [1 .. 18]
                ++ [RollBack 18]
                ++ map (\s -> Forward s (mkBlock s)) [19 .. 40]
        canonicalBlocks =
            resolveCanonical canonicalEvents

    putStrLn $
        "  Canonical chain length: "
            ++ show (length canonicalBlocks)

    -- Single-pass in a fresh temp DB
    singlePassState <- withTempDB $ \runTx2 -> do
        r' <- start backend
        _ <-
            foldPhaseSimple
                runTx2
                (InRestoration r')
                canonicalBlocks
        snapshotState runTx2

    putStrLn ""
    if finalState == singlePassState
        then
            putStrLn
                "  PASS: states match."
        else do
            putStrLn
                "  MISMATCH: states differ!"
            printSnapshot "lifecycle" finalState
            printSnapshot
                "single-pass"
                singlePassState

    -- Also verify phase 5 state is consistent
    -- with canonical chain up to slot 25
    let canonical25 =
            resolveCanonical $
                map (\s -> Forward s (mkBlock s)) [1 .. 18]
                    ++ [RollBack 18]
                    ++ map (\s -> Forward s (mkBlock s)) [19 .. 25]
    singlePass25 <- withTempDB $ \runTx3 -> do
        r'' <- start backend
        _ <-
            foldPhaseSimple
                runTx3
                (InRestoration r'')
                canonical25
        snapshotState runTx3

    if stateAfterPhase5 == singlePass25
        then
            putStrLn
                "  PASS: phase 5 state matches canonical."
        else do
            putStrLn
                "  MISMATCH: phase 5 differs!"
            printSnapshot "phase5" stateAfterPhase5
            printSnapshot "canonical25" singlePass25

    putStrLn ""
    putStrLn "  Tutorial complete."
    putStrLn ""

-- * In-memory type aliases

-- | In-memory column family type.
type MemCF = Int

-- | In-memory operation type.
type MemOp = (Int, ByteString, Maybe ByteString)

-- | Concrete phase for the tutorial.
type TutPhase =
    Phase
        IO
        MemCF
        AllCols
        MemOp
        Block
        ComposedInv
        Int

-- | Concrete following for the tutorial.
type TutFollowing =
    Following
        IO
        (Transaction IO MemCF AllCols MemOp)
        Block
        ComposedInv
        Int

-- * Phase fold helpers

{- | Process a sequence of slots, calling an
action after each.
-}
foldPhase
    :: RunTx MemCF MemOp
    -> Bool
    -> TutPhase
    -> [Int]
    -> (Int -> IO ())
    -> IO TutPhase
foldPhase runTx atTip = go
  where
    go phase [] _ = pure phase
    go phase (slot : rest) after = do
        phase' <-
            processBlock
                nullTracer
                atTip
                runTx
                Rollbacks
                rollbackWindow
                slot
                (mkBlock slot)
                phase
        after slot
        go phase' rest after

{- | Process blocks without per-slot actions
(for verification).
-}
foldPhaseSimple
    :: RunTx MemCF MemOp
    -> TutPhase
    -> [(Int, Block)]
    -> IO TutPhase
foldPhaseSimple _ phase [] = pure phase
foldPhaseSimple runTx phase ((slot, block) : rest) =
    do
        phase' <-
            processBlock
                nullTracer
                False
                runTx
                Rollbacks
                rollbackWindow
                slot
                block
                phase
        foldPhaseSimple runTx phase' rest

-- | Extract Following and count from a phase, or error.
extractFollowing :: TutPhase -> IO (Int, TutFollowing)
extractFollowing (InFollowing n f) = pure (n, f)
extractFollowing (InRestoration _) =
    error "extractFollowing: still in restoration"
