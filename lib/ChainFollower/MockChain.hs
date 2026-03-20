module ChainFollower.MockChain
    ( -- * Block tree
      BlockTree (..)
    , treeSlot

      -- * Chain events
    , ChainEvent (..)

      -- * Tree operations
    , dfs
    , canonicalPath
    , resolveCanonical

      -- * Well-formedness
    , depth
    , wellFormed
    ) where

{- |
Module      : ChainFollower.MockChain
Description : Mock blockchain with forks for testing
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Models a blockchain with forks as a rose tree,
parameterized over slot and block types. Provides
a deterministic DFS walk (what the chain follower
sees) and canonical path extraction (the rightmost
path = the final chain).

Mirrors the Lean formalization in
@lean\/ChainFollower\/BlockTree.lean@.

The slot type must support 'Ord' for rollback
target comparison.
-}

{- | A blockchain with forks.

Children are ordered: leftmost = first explored,
rightmost = canonical.
-}
data BlockTree slot block
    = -- | A single block, no forks.
      Leaf slot block
    | -- | A block with ordered children (forks).
      Fork slot block [BlockTree slot block]
    deriving stock (Show)

-- | The slot at the root of a tree.
treeSlot :: BlockTree slot block -> slot
treeSlot (Leaf s _) = s
treeSlot (Fork s _ _) = s

-- | A chain event: forward or rollback.
data ChainEvent slot block
    = -- | Process a new block at this slot.
      Forward slot block
    | -- | Fork: roll back to this slot.
      RollBack slot
    deriving stock (Show)

-- | Depth of a tree.
depth :: BlockTree slot block -> Int
depth (Leaf _ _) = 1
depth (Fork _ _ children) =
    1 + foldl max 0 (map depth children)

{- | A tree is well-formed w.r.t. stability window K
if every non-rightmost subtree has depth ≤ K and
all subtrees are recursively well-formed.
-}
wellFormed
    :: Int -> BlockTree slot block -> Bool
wellFormed _ (Leaf _ _) = True
wellFormed _ (Fork _ _ []) = True
wellFormed k (Fork _ _ children) =
    let nonRightmost = init children
    in  all (\c -> depth c <= k) nonRightmost
            && all (wellFormed k) children

{- | DFS walk of the tree — the unique left-to-right
traversal. Between non-rightmost children, emits a
'RollBack' to the parent slot.
Mirrors Lean @dfs@.
-}
dfs :: BlockTree slot block -> [ChainEvent slot block]
dfs = dfsSubtree
  where
    dfsSubtree (Leaf s b) = [Forward s b]
    dfsSubtree (Fork s b children) =
        Forward s b
            : interleave
                s
                (map dfsSubtree children)
    interleave _ [] = []
    interleave _ [w] = w
    interleave s (w : ws) =
        w ++ [RollBack s] ++ interleave s ws

{- | The rightmost (canonical) path from root to leaf.
Mirrors Lean @canonical@.
-}
canonicalPath
    :: BlockTree slot block -> [(slot, block)]
canonicalPath (Leaf s b) = [(s, b)]
canonicalPath (Fork s b []) = [(s, b)]
canonicalPath (Fork s b cs) =
    (s, b) : canonicalPath (last cs)

{- | Resolve a flat sequence of chain events into
the canonical chain. Each 'RollBack' drops all
entries with slot > target.
-}
resolveCanonical
    :: (Ord slot)
    => [ChainEvent slot block]
    -> [(slot, block)]
resolveCanonical = foldl apply []
  where
    apply chain (Forward s b) = chain ++ [(s, b)]
    apply chain (RollBack target) =
        filter (\(s, _) -> s <= target) chain
