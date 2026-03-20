module ChainFollower.Backend
    ( -- * Phase continuations
      Restoring (..)
    , Following (..)

      -- * Initialization
    , Init (..)

      -- * Lifting
    , liftRestoring
    , liftFollowing
    , liftInit
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
data Restoring m t block inv meta = Restoring
    { restore
        :: block
        -> t (Restoring m t block inv meta)
    {- ^ Ingest a block. Returns the next continuation.
    No inverse operations, no state to checkpoint.
    -}
    , toFollowing
        :: m (Following m t block inv meta)
    {- ^ Transition to following mode. Runs in @m@
    (not in a transaction) because the transition
    may involve replaying a journal, checkpointing,
    or other IO side effects.
    -}
    }

{- | Following phase continuation.

During following the backend processes blocks near the
chain tip. Each block produces inverse operations and
optional metadata that the chain follower stores for
rollback. The backend's columns are queryable in this
phase.

@t@ — transaction monad (shared with chain follower)
@block@ — the block type
@inv@ — inverse operation type
@meta@ — per-block metadata (e.g. merkle root)
-}
data Following m t block inv meta = Following
    { follow
        :: block
        -> t
            ( inv
            , Maybe meta
            , Following m t block inv meta
            )
    {- ^ Process a block. Returns the inverse operations,
    optional metadata, and the next continuation.
    Runs in @t@ — the chain follower stores both
    @inv@ and @meta@ in the same transaction.
    -}
    , toRestoring
        :: m (Restoring m t block inv meta)
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

{- | Backend initialization.

The chain follower decides which phase to enter based on
its own checkpoint state. The backend provides setup
actions for both phases in @m@, but only the chosen one
is executed. This lets the backend run phase-specific
initialization (replay journals, open cursors, etc.)
without knowing which phase will be selected.
-}
data Init m t block inv meta = Init
    { startRestoring
        :: m (Restoring m t block inv meta)
    {- ^ Set up for restoration mode. Called when
    the chain follower has no checkpoint or is
    starting fresh. Runs in @m@ so the backend
    can initialize internal state.
    -}
    , resumeFollowing
        :: m (Following m t block inv meta)
    {- ^ Set up for following mode. Called when the
    chain follower resumes from a checkpoint near
    the tip. Runs in @m@ so the backend can replay
    journals, restore cursors, etc.
    -}
    }

{- | Lift a 'Restoring' through a natural transformation
on the transaction monad. Used to embed a backend that
operates over its own column GADT into a larger unified
column type via @mapColumns@.
-}
liftRestoring
    :: (Functor m, Functor t)
    => (forall a. t a -> t' a)
    -> Restoring m t block inv meta
    -> Restoring m t' block inv meta
liftRestoring f Restoring{restore, toFollowing} =
    Restoring
        { restore =
            f . fmap (liftRestoring f) . restore
        , toFollowing =
            fmap (liftFollowing f) toFollowing
        }

{- | Lift a 'Following' through a natural transformation
on the transaction monad.
-}
liftFollowing
    :: (Functor m, Functor t)
    => (forall a. t a -> t' a)
    -> Following m t block inv meta
    -> Following m t' block inv meta
liftFollowing f Following{follow, toRestoring, applyInverse} =
    Following
        { follow =
            f
                . fmap
                    ( \(inv, meta, next) ->
                        (inv, meta, liftFollowing f next)
                    )
                . follow
        , toRestoring =
            fmap (liftRestoring f) toRestoring
        , applyInverse =
            f . applyInverse
        }

{- | Lift an 'Init' through a natural transformation
on the transaction monad.
-}
liftInit
    :: (Functor m, Functor t)
    => (forall a. t a -> t' a)
    -> Init m t block inv meta
    -> Init m t' block inv meta
liftInit f Init{startRestoring, resumeFollowing} =
    Init
        { startRestoring =
            fmap (liftRestoring f) startRestoring
        , resumeFollowing =
            fmap (liftFollowing f) resumeFollowing
        }
