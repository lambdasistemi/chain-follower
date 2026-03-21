module ChainFollower.Runner
    ( -- * Chain follower state
      Phase (..)

      -- * Running
    , processBlock
    , rollbackTo

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
data Phase m cf col op block inv meta
    = {- | Restoration: bulk ingestion, no rollback
      support.
      -}
      InRestoration
        (Restoring m (T m cf col op) block inv meta)
    | -- | Following: near tip, rollback support active.
      InFollowing
        (Following m (T m cf col op) block inv meta)

{- | Process a block in the current phase.

In restoration mode, the block is ingested with no
rollback storage. In following mode, the block is
processed and its inverse operations are stored
atomically in the rollback column. Old points
beyond the stability window are pruned automatically.

Returns the updated phase continuation.
-}
processBlock
    :: (Ord slot, GCompare col, Monad m)
    => RollbackCol col slot inv meta
    -- ^ Rollback column selector
    -> Int
    -- ^ Stability window @k@ (keeps @k + 1@ rollback
    --   points: @k@ for the window plus one fence post)
    -> slot
    -- ^ Current slot
    -> block
    -- ^ Block to process
    -> Phase m cf col op block inv meta
    -- ^ Current phase
    -> T
        m
        cf
        col
        op
        (Phase m cf col op block inv meta)
processBlock _ _ _ block (InRestoration restoring) = do
    next <- restore restoring block
    pure $ InRestoration next
processBlock rollbackCol k slot block (InFollowing following) =
    do
        (inv, meta, next) <- follow following block
        Rollbacks.storeRollbackPoint
            rollbackCol
            slot
            RollbackPoint
                { rpInverses = [inv]
                , rpMeta = meta
                }
        _ <- Rollbacks.pruneExcess rollbackCol (k + 1)
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
    => RollbackCol col slot inv meta
    -- ^ Rollback column selector
    -> Following m (T m cf col op) block inv meta
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

