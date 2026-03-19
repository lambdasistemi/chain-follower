module ChainFollower
    ( Follower (..)
    , Intersector (..)
    , ProgressOrRewind (..)
    ) where

{- |
Module      : ChainFollower
Description : Abstract chain follower types
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Generic chain-following abstractions. A 'Follower' processes
blocks rolling forward and handles rollbacks. An 'Intersector'
negotiates the starting point with the chain source.

All types are parameterized over:

* @point@ — the chain point type (e.g. slot + hash)
* @slot@ — the chain tip slot type
* @h@ — the payload delivered on roll-forward (block, header, etc.)
-}

{- | A chain follower that processes items of type @h@.

The follower is a record-of-functions that forms a state machine:
each callback returns the next follower to use, enabling
stateful processing without mutable references.
-}
data Follower point slot h = Follower
    { rollForward
        :: h
        -> slot
        -> IO (Follower point slot h)
    {- ^ Process a new item at the given chain tip slot.
    Returns the next follower state.
    -}
    , rollBackward
        :: point
        -> IO (ProgressOrRewind point slot h)
    {- ^ Handle a rollback to the given point.
    Returns whether to continue, re-intersect,
    or reset.
    -}
    }

-- | Result of a rollback: continue, re-intersect, or reset.
data ProgressOrRewind point slot h
    = -- | Continue following from the rollback point.
      Progress (Follower point slot h)
    | -- | Re-intersect starting from the given points.
      Rewind [point] (Intersector point slot h)
    | -- | Reset to origin and re-intersect.
      Reset (Intersector point slot h)

{- | Negotiates the intersection point with the chain source.

Before following, the client must find a common point
between its local state and the chain source. The
intersector handles this negotiation.
-}
data Intersector point slot h = Intersector
    { intersectFound
        :: point
        -> IO (Follower point slot h)
    {- ^ Called when the chain source found an intersection
    at the given point. Returns the follower to start
    processing from that point.
    -}
    , intersectNotFound
        :: IO (Intersector point slot h, [point])
    {- ^ Called when the chain source did not find any
    intersection. Returns a new intersector and
    alternative points to try.
    -}
    }
