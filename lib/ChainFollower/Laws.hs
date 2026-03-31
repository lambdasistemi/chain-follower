module ChainFollower.Laws
    ( -- * Backend law (from swap_inverse_restores)
      prop_backendIsSwap

      -- * Tree well-formedness (from wellFormed + slotsOrdered)
    , prop_treeWellFormed

      -- * Main theorem (from dfs_equiv_canonical)
    , prop_dfsEquivCanonical

      -- * Metadata history correctness
    , prop_historyMatchesMetadata

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
-- properties ('prop_treeWellFormed', 'prop_dfsEquivCanonical')
-- verify that fork handling is correct.
--
-- ## Lean correspondence
--
-- +-----------------------------------+-------------------------------------------+
-- \| Lean theorem                      | Haskell property                          |
-- +===================================+===========================================+
-- \| @swap_inverse_restores@           | 'prop_backendIsSwap'                      |
-- +-----------------------------------+-------------------------------------------+
-- \| @wellFormed@ + @slotsOrdered@     | 'prop_treeWellFormed'                     |
-- +-----------------------------------+-------------------------------------------+
-- \| @dfs_equiv_canonical@             | 'prop_dfsEquivCanonical'                  |
-- +-----------------------------------+-------------------------------------------+
-- \| @transition_transparency@ (Phase) | 'prop_dfsEquivCanonical' (restoration     |
-- \|                                   | start + immediate transition)             |
-- +-----------------------------------+-------------------------------------------+

import ChainFollower.Backend
    ( Following (..)
    , Init (..)
    , Restoring (..)
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
    , rpMeta
    )
import ChainFollower.Runner
    ( Phase (..)
    , processBlock
    , rollbackTo
    )
import Control.Monad (foldM, foldM_)
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
data BackendHarness m cf col op slot block inv meta snapshot
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
            meta
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
        :: RollbackCol col slot inv meta
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

The snapshots must be equal.
-}
prop_backendIsSwap
    :: ( MonadIO m
       , Ord slot
       , GCompare col
       , Eq snapshot
       , Show snapshot
       )
    => BackendHarness m cf col op slot block inv meta snapshot
    -> [(slot, block)]
    -- ^ Seed blocks to build up state.
    -> (slot, block)
    -- ^ The block to test the swap on.
    -> m (Maybe String)
    -- ^ 'Nothing' if passed, 'Just' error if failed.
prop_backendIsSwap h seed (slot, block) =
    bhWithFreshDB h $ \runTx -> do
        -- Setup: sentinel + start in restoration,
        -- immediately transition to following
        runTx $
            Rollbacks.armageddonSetup
                (bhRollbackCol h)
                (bhSentinel h)
                Nothing
        restoring <- start (bhInit h)
        phase <-
            foldM
                ( \p (s, b) ->
                    processBlock
                        True
                        runTx
                        (pure ())
                        (bhRollbackCol h)
                        maxBound
                        s
                        b
                        p
                )
                (InRestoration restoring)
                seed
        -- Ensure we're in following mode
        phase' <- case phase of
            InRestoration r -> do
                f <- toFollowing r
                n <- runTx $ Rollbacks.countPoints (bhRollbackCol h)
                pure $ InFollowing n f
            _ -> pure phase
        -- Snapshot before
        before <- bhSnapshot h runTx
        -- Follow one block
        case phase' of
            InFollowing _ f -> do
                (inv, meta, f') <-
                    runTx $ follow f block
                -- Store the rollback point
                runTx $
                    Rollbacks.storeRollbackPoint
                        (bhRollbackCol h)
                        slot
                        RollbackPoint
                            { rpInverses = [inv]
                            , rpMeta = meta
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
    => BackendHarness m cf col op slot block inv meta snapshot
    -> BlockTree slot block
    -> Maybe String
prop_treeWellFormed h tree
    | not (wellFormed (bhStabilityWindow h) tree) =
        Just "wellFormed violated"
    | not (slotsOrdered tree) =
        Just "slotsOrdered violated"
    | otherwise = Nothing
  where
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
    => BackendHarness m cf col op slot block inv meta snapshot
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

{- | Run a DFS walk through the Runner. Starts in
restoration and transitions to following on the first
block (atTip=True for all blocks, since DFS walks
need rollback support from the start).
-}
runDfsWalk
    :: (MonadIO m, Ord slot, GCompare col)
    => BackendHarness m cf col op slot block inv meta snapshot
    -> [ChainEvent slot block]
    -> m snapshot
runDfsWalk h events =
    bhWithFreshDB h $ \runTx -> do
        runTx $
            Rollbacks.armageddonSetup
                (bhRollbackCol h)
                (bhSentinel h)
                Nothing
        restoring <- start (bhInit h)
        phaseRef <-
            liftIO $ newIORef (InRestoration restoring)
        let processEvent (Forward slot block) = do
                phase <- liftIO $ readIORef phaseRef
                phase' <-
                    processBlock
                        True
                        runTx
                        (pure ())
                        (bhRollbackCol h)
                        maxBound
                        slot
                        block
                        phase
                liftIO $ writeIORef phaseRef phase'
            processEvent (RollBack target) = do
                phase <- liftIO $ readIORef phaseRef
                case phase of
                    InFollowing n f -> do
                        (_, n') <-
                            runTx $
                                rollbackTo
                                    (bhRollbackCol h)
                                    f
                                    n
                                    target
                        liftIO $
                            writeIORef
                                phaseRef
                                (InFollowing n' f)
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
    => BackendHarness m cf col op slot block inv meta snapshot
    -> [(slot, block)]
    -> m snapshot
runCanonical h blocks =
    bhWithFreshDB h $ \runTx -> do
        runTx $
            Rollbacks.armageddonSetup
                (bhRollbackCol h)
                (bhSentinel h)
                Nothing
        restoring <- start (bhInit h)
        foldM_
            ( \phase (slot, block) ->
                processBlock
                    False
                    runTx
                    (pure ())
                    (bhRollbackCol h)
                    maxBound
                    slot
                    block
                    phase
            )
            (InRestoration restoring)
            blocks
        bhSnapshot h runTx

{- | __Metadata history correctness__

After processing a DFS walk (with forks and rollbacks),
'queryHistory' returns exactly the metadata for the
canonical chain. Rolled-back entries are deleted; only
the surviving points remain with the correct metadata
produced by 'follow'.

This verifies that:

1. 'processBlock' stores the metadata from 'follow'
2. 'rollbackTo' deletes rolled-back entries
3. The surviving history matches the canonical path

Requires a function to extract expected metadata from
a block (e.g. total transfer amount).
-}
prop_historyMatchesMetadata
    :: ( MonadIO m
       , Ord slot
       , GCompare col
       , Eq meta
       , Show meta
       , Show slot
       )
    => BackendHarness
        m
        cf
        col
        op
        slot
        block
        inv
        meta
        snapshot
    -> (block -> Maybe meta)
    -- ^ Expected metadata for a block.
    -> [ChainEvent slot block]
    -- ^ DFS walk to process.
    -> [(slot, block)]
    {- ^ Canonical chain (from 'canonicalPath' or
    'resolveCanonical').
    -}
    -> m (Maybe String)
prop_historyMatchesMetadata h blockMeta events canon =
    bhWithFreshDB h $ \runTx -> do
        -- Process the DFS walk
        runTx $
            Rollbacks.armageddonSetup
                (bhRollbackCol h)
                (bhSentinel h)
                Nothing
        restoring <- start (bhInit h)
        phaseRef <-
            liftIO $ newIORef (InRestoration restoring)
        let processEvent (Forward slot block) = do
                phase <- liftIO $ readIORef phaseRef
                phase' <-
                    processBlock
                        True
                        runTx
                        (pure ())
                        (bhRollbackCol h)
                        maxBound
                        slot
                        block
                        phase
                liftIO $ writeIORef phaseRef phase'
            processEvent (RollBack target) = do
                phase <- liftIO $ readIORef phaseRef
                case phase of
                    InFollowing n f -> do
                        (_, n') <-
                            runTx $
                                rollbackTo
                                    (bhRollbackCol h)
                                    f
                                    n
                                    target
                        liftIO $
                            writeIORef
                                phaseRef
                                (InFollowing n' f)
                    InRestoration _ ->
                        error
                            "prop_historyMatchesMetadata:\
                            \ rollback in restoration"
        mapM_ processEvent events
        -- Query history
        history <-
            runTx $
                Rollbacks.queryHistory
                    (bhRollbackCol h)
        -- Drop sentinel, extract metadata
        let actual =
                [ (s, m)
                | (s, rp) <- history
                , s /= bhSentinel h
                , m <- maybe [] pure (rpMeta rp)
                ]
            expected =
                [ (s, m)
                | (s, b) <- canon
                , m <- maybe [] pure (blockMeta b)
                ]
        if actual == expected
            then pure Nothing
            else
                pure $
                    Just $
                        "historyMatchesMetadata failed:"
                            ++ "\n  actual:   "
                            ++ show actual
                            ++ "\n  expected: "
                            ++ show expected
