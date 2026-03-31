module ChainFollower.Runner
    ( -- * Chain follower state
      Phase (..)

      -- * Running
    , processBlock
    , rollbackTo

      -- * Query
    , rollbackCount
    , readCheckpoint
    ) where

-- \|
-- Module      : ChainFollower.Runner
-- Description : Chain follower state machine with rollback support
-- Copyright   : (c) Paolo Veronelli, 2026
-- License     : Apache-2.0
--
-- The chain follower state machine. It holds a 'Phase'
-- (either 'Restoring' or 'Following') and manages rollback
-- storage via @mts:rollbacks@.
--
-- In restoration mode, blocks are ingested with no rollback
-- support. In following mode, each block produces inverse
-- operations that are stored atomically in the same
-- transaction as the backend's mutations.
--
-- The Runner transitions from restoration to following
-- when the caller signals @atTip = True@. The transition
-- calls 'toFollowing' on the backend (which may replay
-- journals) and enters following mode with fresh rollback
-- state.

import ChainFollower.Backend
    ( Following (..)
    , Restoring (..)
    )
import ChainFollower.Rollbacks.Column
    ( RollbackCol
    )
import ChainFollower.Rollbacks.Store qualified as Rollbacks
import ChainFollower.Rollbacks.Types
    ( RollbackPoint (..)
    )
import Database.KV.Transaction
    ( GCompare
    , Transaction
    )

-- | Shorthand for the transaction type used in phases.
type T m cf col op =
    Transaction m cf col op

{- | Current phase of the chain follower.

Each constructor carries a rollback point count,
maintained in sync with the database. Initialized
at 0 on fresh start, then updated by 'processBlock'
and 'rollbackTo'.
-}
data Phase m cf col op block inv meta
    = {- | Restoration: bulk ingestion, no rollback
      support.
      -}
      InRestoration
        (Restoring m (T m cf col op) block inv meta)
    | {- | Following: near tip, rollback support
      active.
      -}
      InFollowing
        !Int
        -- ^ Rollback point count
        (Following m (T m cf col op) block inv meta)

-- | Current number of rollback points.
rollbackCount
    :: Phase m cf col op block inv meta -> Int
rollbackCount (InRestoration _) = 0
rollbackCount (InFollowing n _) = n

{- | Process a block in the current phase.

Takes an @atTip@ signal and a transaction runner.
Returns in @m@ (not @t@) because the restoration →
following transition calls 'toFollowing' which runs
in @m@ (e.g. journal replay).

- @InRestoration@ + @atTip = False@: ingest block
  in transaction, stay in restoration.
- @InRestoration@ + @atTip = True@: ingest block
  in transaction, then call 'toFollowing' in @m@,
  enter following with 0 rollback points.
- @InFollowing@: process block in transaction with
  rollback point storage and pruning.
-}
processBlock
    :: (Ord slot, GCompare col, Monad m)
    => Bool
    -- ^ At tip: trigger transition if restoring
    -> (forall a. T m cf col op a -> m a)
    -- ^ Transaction runner
    -> RollbackCol col slot inv meta
    -- ^ Rollback column selector
    -> Int
    {- ^ Stability window @k@ (keeps @k + 1@ rollback
    points: @k@ for the window plus one fence post)
    -}
    -> slot
    -- ^ Current slot
    -> block
    -- ^ Block to process
    -> Phase m cf col op block inv meta
    -- ^ Current phase
    -> m (Phase m cf col op block inv meta)
processBlock
    atTip
    runTx
    rollbackCol
    k
    slot
    block
    (InRestoration restoring) =
        if atTip
            then do
                -- Transition first, then process via follow
                following <- toFollowing restoring
                n <- runTx $ Rollbacks.countPoints rollbackCol
                processBlock
                    atTip
                    runTx
                    rollbackCol
                    k
                    slot
                    block
                    (InFollowing n following)
            else do
                next <- runTx $ do
                    r <- restore restoring block
                    -- Checkpoint: store current slot as
                    -- sentinel rollback point (no inverses)
                    Rollbacks.storeRollbackPoint
                        rollbackCol
                        slot
                        RollbackPoint
                            { rpInverses = []
                            , rpMeta = Nothing
                            }
                    pure r
                pure $ InRestoration next
processBlock
    _
    runTx
    rollbackCol
    k
    slot
    block
    (InFollowing n following) =
        runTx $ do
            (inv, meta, next) <- follow following block
            Rollbacks.storeRollbackPoint
                rollbackCol
                slot
                RollbackPoint
                    { rpInverses = [inv]
                    , rpMeta = meta
                    }
            let n' = n + 1
            pruned <-
                Rollbacks.pruneExcess
                    rollbackCol
                    n'
                    (k + 1)
            pure $ InFollowing (n' - pruned) next

{- | Roll back to the given slot.

Reads stored inverse operations from the rollback column
and applies them via the backend's 'applyInverse'. Returns
the rollback result and the updated phase.

Only valid in following mode — restoration has no rollback
support.
-}
rollbackTo
    :: (Ord slot, Monad m, GCompare col)
    => RollbackCol col slot inv meta
    -- ^ Rollback column selector
    -> Following m (T m cf col op) block inv meta
    -- ^ Current following continuation
    -> Int
    -- ^ Current rollback point count
    -> slot
    -- ^ Target slot to roll back to
    -> T
        m
        cf
        col
        op
        (Rollbacks.RollbackResult, Int)
rollbackTo rollbackCol following count target = do
    result <-
        Rollbacks.rollbackTo
            rollbackCol
            ( \RollbackPoint{rpInverses} ->
                mapM_ (applyInverse following) rpInverses
            )
            target
    let count' = case result of
            Rollbacks.RollbackSucceeded deleted ->
                count - deleted
            Rollbacks.RollbackImpossible -> count
    pure (result, count')

{- | Read the restoration checkpoint from the
rollback column. Returns the latest slot if present,
'Nothing' if no blocks have been processed.

Use this on startup to determine the intersection
point for chain sync.
-}
readCheckpoint
    :: (Monad m, GCompare col)
    => RollbackCol col slot inv meta
    -- ^ Rollback column selector
    -> T m cf col op (Maybe slot)
readCheckpoint = Rollbacks.queryTip
