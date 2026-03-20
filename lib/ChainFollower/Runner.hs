module ChainFollower.Runner
    ( -- * Chain follower state
      Phase (..)

      -- * Running
    , processBlock
    , rollbackTo

      -- * Finality
    , pruneOldPoints
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
-- The chain follower decides phase transitions based on
-- external signals (proximity to tip). The backend always
-- offers both options via its CPS continuations.

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

-- | Current phase of the chain follower.
data Phase m cf col op block inv
    = {- | Restoration: bulk ingestion, no rollback
      support.
      -}
      InRestoration
        (Restoring m (T m cf col op) block inv)
    | -- | Following: near tip, rollback support active.
      InFollowing
        (Following m (T m cf col op) block inv)

{- | Process a block in the current phase.

In restoration mode, the block is ingested with no
rollback storage. In following mode, the block is
processed and its inverse operations are stored
atomically in the rollback column.

Returns the updated phase continuation.
-}
processBlock
    :: (Ord slot, GCompare col, Monad m)
    => RollbackCol col slot inv ()
    -- ^ Rollback column selector
    -> slot
    -- ^ Current slot
    -> block
    -- ^ Block to process
    -> Phase m cf col op block inv
    -- ^ Current phase
    -> T
        m
        cf
        col
        op
        (Phase m cf col op block inv)
processBlock _ _ block (InRestoration restoring) = do
    next <- restore restoring block
    pure $ InRestoration next
processBlock rollbackCol slot block (InFollowing following) =
    do
        (inv, next) <- follow following block
        Rollbacks.storeRollbackPoint
            rollbackCol
            slot
            RollbackPoint
                { rpInverses = [inv]
                , rpMeta = Nothing
                }
        pure $ InFollowing next

{- | Roll back to the given slot.

Reads stored inverse operations from the rollback column
and applies them via the backend's 'applyInverse'. Returns
the rollback result.

Only valid in following mode — restoration has no rollback
support.
-}
rollbackTo
    :: (Ord slot, Monad m, GCompare col)
    => RollbackCol col slot inv ()
    -- ^ Rollback column selector
    -> Following m (T m cf col op) block inv
    -- ^ Current following continuation
    -> slot
    -- ^ Target slot to roll back to
    -> T m cf col op Rollbacks.RollbackResult
rollbackTo rollbackCol following =
    Rollbacks.rollbackTo
        rollbackCol
        ( \RollbackPoint{rpInverses} ->
            mapM_ (applyInverse following) rpInverses
        )

{- | Prune rollback points below the finality slot.

Call periodically to free storage. Points before the
finality slot can never be rolled back to.
-}
pruneOldPoints
    :: (Ord slot, Monad m, GCompare col)
    => RollbackCol col slot inv ()
    -- ^ Rollback column selector
    -> slot
    -- ^ Finality slot (prune strictly below)
    -> T m cf col op Int
pruneOldPoints = Rollbacks.pruneBelow
