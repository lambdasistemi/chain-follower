# Backend Laws

The Laws module ([source][laws-src]) provides three testable properties derived
from Lean theorems. Together they form the correctness contract for any chain
follower backend.

[laws-src]: https://github.com/lambdasistemi/chain-follower/blob/feat/rollback-support/lib/ChainFollower/Laws.hs

## Theorem-Property Correspondence

| Lean theorem | QC property | What it tests |
|---|---|---|
| `swap_inverse_restores` | `prop_backendIsSwap` | Following a block then applying its inverse restores the original state |
| `wellFormed` + `slotsOrdered` | `prop_treeWellFormed` | The block tree respects the stability window and has ordered slots |
| `dfs_equiv_canonical` | `prop_dfsEquivCanonical` | Processing the DFS walk produces the same state as the canonical chain |

## prop_backendIsSwap

Derived from Lean `swap_inverse_restores`. This is the fundamental backend
contract.

**Test procedure:**

1. Build a non-trivial state by following seed blocks.
2. Snapshot the state.
3. Follow one more block, capturing the inverse.
4. Apply the inverse.
5. Snapshot again.
6. Assert the two snapshots are equal.

If this property fails, the backend has a bug: its `follow` and `applyInverse`
are not proper inverses.

## prop_treeWellFormed

Derived from Lean `wellFormed` + `slotsOrdered`. This is the chain source
contract.

**Checks:**

- All non-rightmost branches have depth at most K (the stability window).
- Parent slots are strictly less than child slots.

If this property fails, the test generator is producing invalid trees or the
chain source is violating the stability window.

## prop_dfsEquivCanonical

Derived from Lean `dfs_equiv_canonical`. This is the main correctness theorem.

**Test procedure:**

1. Generate a well-formed block tree.
2. Run the DFS walk through the Runner (following mode + rollbacks).
3. Run the canonical path through the Runner (restoration mode, no rollbacks).
4. Assert the final states are equal.

If `prop_backendIsSwap` and `prop_treeWellFormed` both pass but this property
fails, the bug is in the library (Runner or Store), not in the backend.

## BackendHarness

Users instantiate `BackendHarness` to test their backend:

```haskell
data BackendHarness m cf col op slot block inv snapshot
    = BackendHarness
    { bhInit         :: Init m (Transaction m cf col op) block inv
    , bhSnapshot     :: (forall a. Transaction m cf col op a -> m a) -> m snapshot
    , bhWithFreshDB  :: forall a. ((forall b. Transaction m cf col op b -> m b) -> m a) -> m a
    , bhRollbackCol  :: RollbackCol col slot inv ()
    , bhStabilityWindow :: Int
    , bhSentinel     :: slot
    }
```

| Field | Purpose |
|-------|---------|
| `bhInit` | The backend's `Init`, lifted into the full column type |
| `bhSnapshot` | Capture application state as a comparable snapshot |
| `bhWithFreshDB` | Bracket that provides a fresh database and transaction runner |
| `bhRollbackCol` | Column selector for the rollback column |
| `bhStabilityWindow` | Maximum depth of non-canonical branches (K) |
| `bhSentinel` | Slot value that sorts before all block slots |

## Usage Example

```haskell
import ChainFollower.Laws

harness :: BackendHarness IO ColumnFamily AllCols BatchOp Int Block Inv Snapshot
harness = BackendHarness
    { bhInit = liftInit (mapColumns InBackend) myInit
    , bhSnapshot = \runTx -> snapshotState runTx
    , bhWithFreshDB = \action -> withTempDB (\runTx -> action runTx)
    , bhRollbackCol = Rollbacks
    , bhStabilityWindow = 5
    , bhSentinel = 0
    }

spec :: Spec
spec = do
    prop_backendIsSwap harness seedBlocks testBlock
    prop_treeWellFormed harness sampleTree
    prop_dfsEquivCanonical harness sampleTree
```

## Diagnostic Guide

!!! tip "Which property failed?"
    - **`prop_backendIsSwap` fails** -- backend bug. The `follow`/`applyInverse`
      pair does not round-trip. Check that every column mutation produces a
      correct inverse.
    - **`prop_treeWellFormed` fails** -- chain source bug (or generator bug).
      The block tree violates the stability window or has misordered slots.
    - **`prop_dfsEquivCanonical` fails but `prop_backendIsSwap` passes** --
      library bug. The Runner or Store is not correctly applying or storing
      inverses. File an issue.
