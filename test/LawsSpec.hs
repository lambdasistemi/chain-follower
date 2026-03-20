module LawsSpec (spec) where

-- \| Verify that the tutorial backend (Balances + Audit)
-- satisfies all three laws from ChainFollower.Laws.

import ChainFollower.Backend (liftInit)
import ChainFollower.Laws
    ( BackendHarness (..)
    , prop_backendIsSwap
    , prop_dfsEquivCanonical
    , prop_historyMatchesMetadata
    , prop_treeWellFormed
    )
import ChainFollower.MockChain
    ( BlockTree (..)
    , canonicalPath
    , dfs
    )
import Composed (ComposedInv, composedInit)
import Database.KV.Transaction (mapColumns)
import Database.RocksDB (BatchOp, ColumnFamily)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    )
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck
    ( Gen
    , chooseInt
    , elements
    , forAll
    , listOf1
    , property
    )
import TutorialDB
    ( AllCols (..)
    , StateSnapshot
    , accounts
    , rollbackWindow
    , snapshotState
    , withTempDB
    )
import Types (Block (..), Transfer (..))

-- | The tutorial backend harness.
harness
    :: BackendHarness
        IO
        ColumnFamily
        AllCols
        BatchOp
        Int
        Block
        ComposedInv
        Int
        StateSnapshot
harness =
    BackendHarness
        { bhInit =
            liftInit
                (mapColumns InBackend)
                composedInit
        , bhSnapshot = snapshotState
        , bhWithFreshDB = withTempDB
        , bhRollbackCol = Rollbacks
        , bhStabilityWindow = rollbackWindow
        , bhSentinel = 0
        }

-- | Slot base for consistent key encoding.
slotBase :: Int
slotBase = 100

-- | Generate a random transfer.
genTransfer :: Gen Transfer
genTransfer =
    Transfer
        <$> elements accounts
        <*> elements accounts
        <*> chooseInt (1, 3000)

-- | Generate a random block at a given slot.
genBlock :: Int -> Gen Block
genBlock slot =
    Block slot <$> listOf1 genTransfer

-- | Generate seed blocks as (slot, block) pairs.
genSeedBlocks :: Gen [(Int, Block)]
genSeedBlocks = do
    n <- chooseInt (0, 10)
    mapM
        ( \i -> do
            b <- genBlock (slotBase + i)
            pure (slotBase + i, b)
        )
        [0 .. n - 1]

-- | Generate a single test block.
genTestBlock :: Int -> Gen (Int, Block)
genTestBlock slot = do
    b <- genBlock slot
    pure (slot, b)

-- | Generate a well-formed block tree.
genTree :: Gen (BlockTree Int Block)
genTree = genBlockTree slotBase

genBlockTree :: Int -> Gen (BlockTree Int Block)
genBlockTree nextSlot = do
    nChildren <- chooseInt (0 :: Int, 3)
    block <- genBlock nextSlot
    if nChildren == 0
        then pure $ Leaf nextSlot block
        else do
            let mkShallow s = do
                    d <- chooseInt (1, rollbackWindow)
                    genBounded s d
                mkDeep = genBlockTree
            children <- case nChildren of
                1 -> do
                    c <- mkDeep (nextSlot + 1)
                    pure [c]
                _ -> do
                    nonRight <-
                        mapM
                            mkShallow
                            [ nextSlot + 1
                            .. nextSlot + nChildren - 1
                            ]
                    right <-
                        mkDeep
                            (nextSlot + nChildren)
                    pure $ nonRight ++ [right]
            pure $ Fork nextSlot block children

genBounded
    :: Int -> Int -> Gen (BlockTree Int Block)
genBounded nextSlot maxDepth = do
    block <- genBlock nextSlot
    if maxDepth <= 1
        then pure $ Leaf nextSlot block
        else do
            nChildren <- chooseInt (0 :: Int, 2)
            if nChildren == 0
                then pure $ Leaf nextSlot block
                else do
                    children <-
                        mapM
                            ( \s ->
                                genBounded
                                    s
                                    (maxDepth - 1)
                            )
                            [ nextSlot + 1
                            .. nextSlot + nChildren
                            ]
                    pure $
                        Fork nextSlot block children

-- | Assert a law result.
assertLaw :: IO (Maybe String) -> IO ()
assertLaw action = do
    result <- action
    mapM_ expectationFailure result

spec :: Spec
spec =
    describe "Laws" $
        modifyMaxSuccess (const 50) $ do
            describe
                "prop_backendIsSwap (swap_inverse_restores)"
                $ do
                    it
                        "follow + applyInverse = identity"
                        $ forAll
                            ( (,)
                                <$> genSeedBlocks
                                <*> genTestBlock
                                    (slotBase + 10)
                            )
                        $ \(seed, testBlock) ->
                            property $
                                assertLaw $
                                    prop_backendIsSwap
                                        harness
                                        seed
                                        testBlock

            describe
                "prop_treeWellFormed (wellFormed + slotsOrdered)"
                $ do
                    it "generated trees are well-formed" $
                        forAll genTree $ \tree ->
                            case prop_treeWellFormed
                                harness
                                tree of
                                Nothing -> property True
                                Just _ ->
                                    property False

            describe
                "prop_dfsEquivCanonical (dfs_equiv_canonical)"
                $ do
                    it
                        "DFS walk = canonical path"
                        $ forAll genTree
                        $ \tree ->
                            property $
                                assertLaw $
                                    prop_dfsEquivCanonical
                                        harness
                                        tree

            describe
                "prop_historyMatchesMetadata"
                $ do
                    it
                        "history after forks matches canonical metadata"
                        $ forAll genTree
                        $ \tree ->
                            property $
                                assertLaw $
                                    prop_historyMatchesMetadata
                                        harness
                                        blockMeta
                                        (dfs tree)
                                        (canonicalPath tree)

-- | Expected metadata: total transfer amount.
blockMeta :: Block -> Maybe Int
blockMeta block =
    Just $
        sum
            [ transferAmount t
            | t <- blockTransfers block
            ]
