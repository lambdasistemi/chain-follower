module RunnerSpec (spec) where

import ChainFollower.Backend
    ( Init (..)
    , liftInit
    )
import ChainFollower.Rollbacks.Store qualified as Rollbacks
import ChainFollower.Runner
    ( Phase (..)
    , processBlock
    , rollbackTo
    )
import Composed (ComposedInv, composedInit)
import Control.Monad (foldM, forM_, when)
import Data.Function (fix)
import Data.IORef
    ( newIORef
    , readIORef
    , writeIORef
    )
import Database.KV.Transaction
    ( Transaction
    , mapColumns
    )
import Database.RocksDB (BatchOp, ColumnFamily)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck
    ( Gen
    , chooseInt
    , forAll
    , property
    )
import TutorialDB
    ( AllCols (..)
    , ChainEvent (..)
    , RunTx
    , StateSnapshot
    , mkBlock
    , resolveCanonical
    , rollbackWindow
    , snapshotState
    , withTempDB
    )
import Types (Block (..))

-- | The backend lifted into the full column type.
backend
    :: Init
        IO
        ( Transaction
            IO
            ColumnFamily
            AllCols
            BatchOp
        )
        Block
        ComposedInv
backend = liftInit (mapColumns InBackend) composedInit

{- | Slot offset: all test slots start at this value
to ensure consistent lexicographic/numeric ordering
in the RocksDB key encoding (all slots have 3 digits).
-}
slotBase :: Int
slotBase = 100

-- | Run a sequence of chain events through the Runner.
runChainEvents
    :: RunTx -> [ChainEvent] -> IO StateSnapshot
runChainEvents runTx events = do
    -- Start in following mode so all blocks have
    -- rollback support from the beginning.
    -- Sentinel at 0 so it sorts before all block slots
    -- in RocksDB lexicographic ordering.
    runTx $
        Rollbacks.armageddonSetup Rollbacks 0 Nothing
    following <- resumeFollowing backend
    phaseRef <- newIORef (InFollowing following)

    forM_ events $ \event -> do
        phase <- readIORef phaseRef
        case event of
            Forward block -> do
                newPhase <-
                    runTx $
                        processBlock
                            Rollbacks
                            (blockSlot block)
                            block
                            phase
                writeIORef phaseRef newPhase
            RollBack target -> do
                case phase of
                    InFollowing f -> do
                        result <-
                            runTx $
                                rollbackTo
                                    Rollbacks
                                    f
                                    target
                        case result of
                            Rollbacks.RollbackSucceeded _ ->
                                pure ()
                            Rollbacks.RollbackImpossible ->
                                error $
                                    "runChainEvents: rollback"
                                        ++ " impossible to "
                                        ++ show target
                    InRestoration _ ->
                        error $
                            "runChainEvents: rollback"
                                ++ " in restoration"

    snapshotState runTx

-- | Run the canonical chain cleanly via restoration.
runCanonicalClean
    :: RunTx -> [Block] -> IO StateSnapshot
runCanonicalClean runTx blocks = do
    runTx $
        Rollbacks.armageddonSetup Rollbacks 0 Nothing
    restoring <- startRestoring backend
    _ <-
        foldM
            ( \phase block ->
                runTx $
                    processBlock
                        Rollbacks
                        (blockSlot block)
                        block
                        phase
            )
            (InRestoration restoring)
            blocks
    snapshotState runTx

-- * Generators

{- | Generate a sequence of chain events with forks.
Slots start at 'slotBase' so all slot numbers have
the same digit count (avoids lexicographic ordering
issues in RocksDB key encoding).
-}
genChainEvents :: Gen [ChainEvent]
genChainEvents = do
    totalEvents <- chooseInt (10, 30)
    go slotBase 0 totalEvents []
  where
    go
        :: Int
        -> Int
        -> Int
        -> [ChainEvent]
        -> Gen [ChainEvent]
    go _nextSlot _tip 0 acc = pure (reverse acc)
    go nextSlot tip remaining acc
        | tip < 3 = do
            -- Must go forward until we have >= 3 blocks
            let block = mkBlock nextSlot
                event = Forward block
            go
                (nextSlot + 1)
                (tip + 1)
                (remaining - 1)
                (event : acc)
        | otherwise = do
            choice <- chooseInt (1 :: Int, 4)
            if choice == 1 && tip > 1
                then do
                    -- Rollback
                    let lo =
                            max
                                slotBase
                                (nextSlot - 1 - rollbackWindow)
                        hi = nextSlot - 2
                    target <- chooseInt (lo, hi)
                    let newTip =
                            length
                                ( resolveCanonical
                                    ( reverse
                                        (RollBack target : acc)
                                    )
                                )
                    go
                        (target + 1)
                        newTip
                        (remaining - 1)
                        (RollBack target : acc)
                else do
                    let block = mkBlock nextSlot
                        event = Forward block
                    go
                        (nextSlot + 1)
                        (tip + 1)
                        (remaining - 1)
                        (event : acc)

-- * Properties

spec :: Spec
spec =
    describe "Runner" $
        modifyMaxSuccess (const 30) $ do
            describe "Fork resolution" $ do
                it "matches canonical chain after forks" $
                    forAll genChainEvents $ \events ->
                        property $ do
                            let canonical =
                                    resolveCanonical events
                            actual <- withTempDB $ \runTx ->
                                runChainEvents runTx events
                            expected <- withTempDB $ \runTx ->
                                runCanonicalClean runTx canonical
                            actual `shouldBe` expected

            describe "Rollback within window" $ do
                it "rollback to slot K matches snapshot at K" $
                    forAll (chooseInt (1, rollbackWindow)) $
                        \n ->
                            property $ withTempDB $ \runTx ->
                                do
                                    runTx $
                                        Rollbacks.armageddonSetup
                                            Rollbacks
                                            0
                                            Nothing
                                    following <-
                                        resumeFollowing backend
                                    -- Follow n blocks from slotBase
                                    snapshotsRef <- newIORef []
                                    _ <-
                                        foldM
                                            ( \phase slot -> do
                                                newPhase <-
                                                    runTx $
                                                        processBlock
                                                            Rollbacks
                                                            slot
                                                            (mkBlock slot)
                                                            phase
                                                snap <-
                                                    snapshotState
                                                        runTx
                                                snapshots <-
                                                    readIORef
                                                        snapshotsRef
                                                writeIORef
                                                    snapshotsRef
                                                    ( snapshots
                                                        ++ [(slot, snap)]
                                                    )
                                                pure newPhase
                                            )
                                            (InFollowing following)
                                            [ slotBase
                                            .. slotBase + n - 1
                                            ]
                                    -- Rollback to first block
                                    let target = slotBase
                                    _ <-
                                        runTx $
                                            rollbackTo
                                                Rollbacks
                                                following
                                                target
                                    actual <- snapshotState runTx
                                    snapshots <-
                                        readIORef snapshotsRef
                                    case snapshots of
                                        ((_, expected) : _) ->
                                            actual
                                                `shouldBe` expected
                                        [] ->
                                            error
                                                "no snapshots"

            describe "Armageddon resync" $ do
                it "cleanup + fresh re-restore matches canonical" $
                    forAll genChainEvents $ \events ->
                        property $ do
                            let canonical =
                                    resolveCanonical events
                            -- Run events, then armageddon cleanup
                            withTempDB $ \runTx -> do
                                _ <-
                                    runChainEvents
                                        runTx
                                        events
                                -- Armageddon cleanup empties
                                -- rollback column
                                fix $ \go -> do
                                    more <-
                                        runTx
                                            ( Rollbacks.armageddonCleanup
                                                Rollbacks
                                                100
                                            )
                                    when more go
                                -- Verify rollback column is empty
                                nPoints <-
                                    runTx $
                                        Rollbacks.countPoints
                                            Rollbacks
                                nPoints `shouldBe` 0
                            -- Fresh DB re-restore matches clean
                            actual <- withTempDB $ \runTx ->
                                runCanonicalClean runTx canonical
                            expected <- withTempDB $ \runTx ->
                                runCanonicalClean runTx canonical
                            actual `shouldBe` expected

            describe "Stop and restart" $ do
                it "fresh DB with canonical matches complete run" $
                    forAll genChainEvents $ \events ->
                        property $ do
                            let canonical =
                                    resolveCanonical events
                            actual <- withTempDB $ \runTx ->
                                runChainEvents runTx events
                            expected <- withTempDB $ \runTx ->
                                runCanonicalClean runTx canonical
                            actual `shouldBe` expected
