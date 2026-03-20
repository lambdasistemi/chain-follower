# Test Suite

The test suite validates the chain follower against a concrete RocksDB-backed
tutorial backend.

## Running Tests

```bash
nix develop -c cabal test
```

## Test Modules

### RunnerSpec

Tests the Runner state machine with generated chain events and block trees.

**Generators:**

- `genChainEvents` -- generates a flat sequence of `Forward` and `RollBack`
  events. Slots start at 100 (consistent digit count for RocksDB key encoding).
  Rollbacks are constrained to the stability window.
- `genBlockTree` -- generates a well-formed `BlockTree` where non-rightmost
  branches have depth at most `rollbackWindow`. Mirrors Lean `wellFormed`.
- `genBoundedTree` -- helper that generates trees with a hard depth bound.

**Properties:**

| Test | What it checks |
|------|----------------|
| DFS walk of tree equals canonical path | `dfs_equiv_canonical` -- the main theorem. DFS walk through Runner in following mode produces same state as canonical path through restoration mode. |
| Fork resolution (flat events) | Same as above but with flat `genChainEvents` instead of tree-shaped input. Uses `resolveCanonical` as the reference. |
| Rollback within window | Follow N blocks, snapshot at each step, roll back to first block, verify state matches the snapshot taken after that block. |
| Armageddon resync | Run events, then `armageddonCleanup` until empty, verify rollback column has zero points. Fresh re-restore matches clean. |
| Stop and restart | Run events through the Runner, compare with clean canonical restore on a fresh database. |

### LifecycleSpec

Tests phase transitions and persistence.

| Test | What it checks |
|------|----------------|
| Fresh start | Restore 10 blocks, transition to following, follow 5 more. Verify state matches restoring all 15 blocks directly. |
| Phase equivalence | Restoring N blocks produces the same state as following N blocks (the backend must be phase-agnostic for final state). |
| Persistence across reopens | Follow blocks, close DB, reopen, verify tip query returns correct slot and state snapshot matches. |

## Adding Tests for a New Backend

1. **Implement the backend** with its own column GADT, `Init`, `follow`,
   `restore`, and `applyInverse`.

2. **Define a unified column GADT** that includes both backend columns and the
   rollback column:

    ```haskell
    data AllCols c where
        InBackend :: MyColumns c -> AllCols c
        Rollbacks :: AllCols (RollbackKV Slot Inv ())
    ```

3. **Lift the Init** into the unified type:

    ```haskell
    liftedInit = liftInit (mapColumns InBackend) myInit
    ```

4. **Write a snapshot function** that captures the backend's observable state
   (read all KV pairs, sorted).

5. **Write a `withTempDB` bracket** that creates a fresh RocksDB instance with
   all column families.

6. **Use the laws** from `ChainFollower.Laws`:

    ```haskell
    harness = BackendHarness { ... }

    spec :: Spec
    spec = do
        it "swap inverse restores" $
            forAll genSeedAndBlock $ \(seed, block) ->
                property $ do
                    result <- prop_backendIsSwap harness seed block
                    result `shouldBe` Nothing
        it "dfs equiv canonical" $
            forAll (genBlockTree 100) $ \tree ->
                property $ do
                    result <- prop_dfsEquivCanonical harness tree
                    result `shouldBe` Nothing
    ```

7. **Optionally add domain-specific tests** (e.g. query correctness after
   rollback, specific edge cases for your column types).
