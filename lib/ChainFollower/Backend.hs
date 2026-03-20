module ChainFollower.Backend
    ( -- * Phase continuations
      Restoring (..)
    , Following (..)

      -- * Initialization
    , Init (..)
    ) where

{- |
Module      : ChainFollower.Backend
Description : CPS backend interface for chain followers
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Continuation-passing backend interface for chain followers.
The backend provides two phase continuations — 'Restoring'
and 'Following' — each as a record with two fields:

* A block processing function (in transaction monad @t@)
* A phase transition function (in outer monad @m@, typically IO)

The chain follower decides which to call based on proximity
to the chain tip. The backend always offers both options.

The @t@ parameter is the transaction monad (from
@kv-transactions@). The backend and the chain follower
share the same @t@, enabling atomic block processing:
the backend mutates its columns and the chain follower
stores rollback data in the same transaction.

The @m@ parameter is the outer monad (typically IO) used
for phase transitions — replay, checkpointing, and other
side effects that happen outside block-level transactions.
-}

{- | Restoration phase continuation.

During restoration the backend ingests blocks at full speed
with no inverse operations, no rollback support, and no
queryable state. The chain follower discards the result
and stores nothing.

@t@ — transaction monad (shared with chain follower)
@block@ — the block type
@inv@ — inverse operation type (used after transition)
-}
data Restoring m t block inv = Restoring
    { restore
        :: block
        -> t (Restoring m t block inv)
    {- ^ Ingest a block. Returns the next continuation.
    No inverse operations, no state to checkpoint.
    -}
    , toFollowing
        :: m (Following m t block inv)
    {- ^ Transition to following mode. Runs in @m@
    (not in a transaction) because the transition
    may involve replaying a journal, checkpointing,
    or other IO side effects.
    -}
    }

{- | Following phase continuation.

During following the backend processes blocks near the
chain tip. Each block produces inverse operations that
the chain follower stores for rollback. The backend's
columns are queryable in this phase.

@t@ — transaction monad (shared with chain follower)
@block@ — the block type
@inv@ — inverse operation type
-}
data Following m t block inv = Following
    { follow
        :: block
        -> t (inv, Following m t block inv)
    {- ^ Process a block. Returns the inverse operations
    (for rollback) and the next continuation.
    Runs in @t@ — the chain follower stores @inv@
    in the same transaction.
    -}
    , toRestoring
        :: m (Restoring m t block inv)
    {- ^ Transition to restoration mode. Runs in @m@
    because the transition may involve cleanup,
    disabling queries, or other IO side effects.
    -}
    , applyInverse
        :: inv -> t ()
    {- ^ Apply an inverse operation to undo the
    backend's state. Called by the chain follower
    during rollback, inside a transaction.
    -}
    }

{- | Backend initialization result.

At startup the chain follower reads its own checkpoint
state to determine which phase to resume. The backend
provides the appropriate continuation.
-}
data Init m t block inv
    = {- | Fresh start or restoration recovery.
      No checkpoints, no inverses, no tip state.
      -}
      StartRestoring
        (Restoring m t block inv)
    | -- | Resuming following mode from a checkpoint.
      ResumeFollowing
        (Following m t block inv)
