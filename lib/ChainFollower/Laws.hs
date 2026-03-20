module ChainFollower.Laws
    ( -- * Backend law (from swap_inverse_restores)
      prop_backendIsSwap

      -- * Tree well-formedness (from wellFormed + slotsOrdered)
    , prop_treeWellFormed

      -- * Main theorem (from dfs_equiv_canonical)
    , prop_dfsEquivCanonical

      -- * Test harness
    , BackendHarness (..)
    , runDfsWalk
    , runCanonical
    ) where

-- \|
-- Module      : ChainFollower.Laws
-- Description : Testable laws for chain follower backends
-- Copyright   : (c) Paolo Veronelli, 2026
-- License     : Apache-2.0
--
-- Testable properties derived from the Lean formalization
-- in @lean\/ChainFollower\/BlockTree.lean@.
--
-- Any backend that satisfies 'prop_backendIsSwap' is
-- guaranteed correct rollback behavior. The chain source
-- must satisfy 'prop_treeWellFormed'. If both hold,
-- 'prop_dfsEquivCanonical' follows.
--
-- __Usage:__ instantiate 'BackendHarness' with your types,
-- then run the three properties in your test suite.
--
-- @
-- harness :: BackendHarness IO Block Snapshot
-- harness = BackendHarness
--     { bhInit = myInit
--     , bhSnapshot = mySnapshot
--     , bhRunTx = \\action -> withMyDB action
--     , bhGenBlock = myBlockGen
--     , bhGenSlot = chooseInt (100, 999)
--     , bhRollbackCol = MyRollbacks
--     , bhStabilityWindow = 5
--     }
--
-- spec :: Spec
-- spec = do
--     prop_backendIsSwap harness
--     prop_treeWellFormed harness
--     prop_dfsEquivCanonical harness
-- @

import ChainFollower.Backend
    ( Following (..)
    , Init (..)
    )
import ChainFollower.MockChain
    ( BlockTree (..)
    , ChainEvent (..)
    , canonicalPath
    , dfs
    , treeSlot
    , wellFormed
    )
import ChainFollower.Rollbacks.Column
    ( RollbackCol
    )
import ChainFollower.Rollbacks.Store qualified as Rollbacks
import ChainFollower.Rollbacks.Types
    ( RollbackPoint (..)
    )
import ChainFollower.Runner
    ( Phase (..)
    , processBlock
    , rollbackTo
    )
import Control.Monad (foldM)
import Control.Monad.IO.Class (MonadIO (..))
import Data.IORef
    ( newIORef
    , readIORef
    , writeIORef
    )
import Database.KV.Transaction
    ( GCompare
    , Transaction
    )

{- | Everything the test harness needs from the user.
Parameterized over:

* @m@ — outer monad (typically IO)
* @cf@ — column family type (e.g. ColumnFamily)
* @col@ — column GADT (must include backend + rollback)
* @op@ — batch operation type (e.g. BatchOp)
* @slot@ — slot type (must be Ord)
* @block@ — block type
* @inv@ — inverse type
* @snapshot@ — state snapshot type (must be Eq, Show)
-}
data BackendHarness m cf col op slot block inv snapshot
    = BackendHarness
    { bhInit
        :: Init
            m
            ( Transaction
                m
                cf
                col
                op
            )
            block
            inv
    {- ^ The backend's Init, already lifted into
    the full column type.
    -}
    , bhSnapshot
        :: ( forall a
              . Transaction m cf col op a
             -> m a
           )
        -> m snapshot
    -- ^ Capture the full application state.
    , bhWithFreshDB
        :: forall a
         . ( ( forall b
                . Transaction m cf col op b
               -> m b
             )
             -> m a
           )
        -> m a
    {- ^ Run an action with a fresh database and
    transaction runner.
    -}
    , bhRollbackCol
        :: RollbackCol col slot inv ()
    -- ^ The rollback column selector.
    , bhStabilityWindow :: Int
    -- ^ Maximum depth of non-canonical branches.
    , bhSentinel :: slot
    {- ^ Sentinel slot for armageddon setup
    (must sort before all block slots).
    -}
    }

{- | __Lean: @swap_inverse_restores@__

For any state and any block, following the block
and then applying its inverse restores the original
state. This is the fundamental backend contract.

Tests this by:

1. Building up a non-trivial state (apply seed blocks)
2. Snapshotting the state
3. Following one more block
4. Applying the inverse
5. Snapshotting again
6. Asserting equality
-}
prop_backendIsSwap
    :: ( MonadIO m
       , Ord slot
       , GCompare col
       , Eq snapshot
       , Show snapshot
       )
    => BackendHarness m cf col op slot block inv snapshot
    -> [(slot, block)]
    -- ^ Seed blocks to build up state.
    -> (slot, block)
    -- ^ The block to test the swap on.
    -> m (Maybe String)
    -- ^ 'Nothing' if passed, 'Just' error if failed.
prop_backendIsSwap h seed (slot, block) =
    bhWithFreshDB h $ \runTx -> do
        -- Setup: sentinel + follow seed blocks
        runTx $
            Rollbacks.armageddonSetup
                (bhRollbackCol h)
                (bhSentinel h)
                Nothing
        following <- resumeFollowing (bhInit h)
        phase <-
            foldM
                ( \p (s, b) ->
                    runTx $
                        processBlock
                            (bhRollbackCol h)
                            s
                            b
                            p
                )
                (InFollowing following)
                seed
        -- Snapshot before
        before <- bhSnapshot h runTx
        -- Follow one block
        case phase of
            InFollowing f -> do
                (inv, f') <-
                    runTx $ follow f block
                -- Store the rollback point
                runTx $
                    Rollbacks.storeRollbackPoint
                        (bhRollbackCol h)
                        slot
                        RollbackPoint
                            { rpInverses = [inv]
                            , rpMeta = Nothing
                            }
                -- Apply inverse
                runTx $ applyInverse f' inv
                -- Delete the rollback point
                runTx $
                    Rollbacks.storeRollbackPoint
                        (bhRollbackCol h)
                        slot
                        RollbackPoint
                            { rpInverses = []
                            , rpMeta = Nothing
                            }
                -- Snapshot after
                after <- bhSnapshot h runTx
                if before == after
                    then pure Nothing
                    else
                        pure $
                            Just $
                                "swap_inverse_restores failed:"
                                    ++ "\n  before: "
                                    ++ show before
                                    ++ "\n  after:  "
                                    ++ show after
            InRestoration _ ->
                pure $
                    Just "unexpected restoration phase"

{- | __Lean: @wellFormed@ + @slotsOrdered@__

The block tree satisfies the stability window
constraint and has properly ordered slots.

Tests:

1. All non-rightmost branches have depth ≤ K
2. Slot at each node < slots of all children
-}
prop_treeWellFormed
    :: (Ord slot)
    => BackendHarness m cf col op slot block inv snapshot
    -> BlockTree slot block
    -> Maybe String
prop_treeWellFormed h tree =
    let k = bhStabilityWindow h
    in  if not (wellFormed k tree)
            then
                Just $
                    "wellFormed "
                        ++ show k
                        ++ " failed"
            else
                if not (slotsOrdered tree)
                    then Just "slotsOrdered failed"
                    else Nothing

{- | Check that parent slots are strictly less than
child slots (mirrors Lean @slotsOrdered@).
-}
slotsOrdered
    :: (Ord slot) => BlockTree slot block -> Bool
slotsOrdered (Leaf _ _) = True
slotsOrdered (Fork s _ children) =
    all (\c -> s < treeSlot c) children
        && all slotsOrdered children

{- | __Lean: @dfs_equiv_canonical@__

Processing the DFS walk of a well-formed block tree
produces the same state as applying the canonical
chain directly.

This is the main correctness property. If
'prop_backendIsSwap' and 'prop_treeWellFormed' hold,
this property should also hold.
-}
prop_dfsEquivCanonical
    :: ( MonadIO m
       , Ord slot
       , GCompare col
       , Eq snapshot
       , Show snapshot
       )
    => BackendHarness m cf col op slot block inv snapshot
    -> BlockTree slot block
    -> m (Maybe String)
prop_dfsEquivCanonical h tree = do
    actual <- runDfsWalk h (dfs tree)
    expected <- runCanonical h (canonicalPath tree)
    if actual == expected
        then pure Nothing
        else
            pure $
                Just $
                    "dfs_equiv_canonical failed:"
                        ++ "\n  dfs walk: "
                        ++ show actual
                        ++ "\n  canonical: "
                        ++ show expected

{- | Run a DFS walk through the Runner in following
mode. Used by 'prop_dfsEquivCanonical'.
-}
runDfsWalk
    :: (MonadIO m, Ord slot, GCompare col)
    => BackendHarness m cf col op slot block inv snapshot
    -> [ChainEvent slot block]
    -> m snapshot
runDfsWalk h events =
    bhWithFreshDB h $ \runTx -> do
        runTx $
            Rollbacks.armageddonSetup
                (bhRollbackCol h)
                (bhSentinel h)
                Nothing
        following <- resumeFollowing (bhInit h)
        phaseRef <- liftIO $ newIORef (InFollowing following)
        let processEvent (Forward slot block) = do
                phase <- liftIO $ readIORef phaseRef
                phase' <-
                    runTx $
                        processBlock
                            (bhRollbackCol h)
                            slot
                            block
                            phase
                liftIO $ writeIORef phaseRef phase'
            processEvent (RollBack target) = do
                phase <- liftIO $ readIORef phaseRef
                case phase of
                    InFollowing f -> do
                        _ <-
                            runTx $
                                rollbackTo
                                    (bhRollbackCol h)
                                    f
                                    target
                        pure ()
                    InRestoration _ ->
                        error
                            "runDfsWalk: rollback in\
                            \ restoration"
        mapM_ processEvent events
        bhSnapshot h runTx

{- | Run a canonical chain cleanly via restoration.
Used by 'prop_dfsEquivCanonical'.
-}
runCanonical
    :: (MonadIO m, Ord slot, GCompare col)
    => BackendHarness m cf col op slot block inv snapshot
    -> [(slot, block)]
    -> m snapshot
runCanonical h blocks =
    bhWithFreshDB h $ \runTx -> do
        runTx $
            Rollbacks.armageddonSetup
                (bhRollbackCol h)
                (bhSentinel h)
                Nothing
        restoring <- startRestoring (bhInit h)
        _ <-
            foldM
                ( \phase (slot, block) ->
                    runTx $
                        processBlock
                            (bhRollbackCol h)
                            slot
                            block
                            phase
                )
                (InRestoration restoring)
                blocks
        bhSnapshot h runTx
