# Tasks: Restoration Checkpoint in Runner

**Feature**: 002-020-restoration-checkpoint
**Plan**: [plan.md](plan.md)

## Phase 1: Runner changes

### Task 1.1: Store checkpoint during restoration
**File**: `lib/ChainFollower/Runner.hs`
**Depends on**: nothing

In `processBlock` `InRestoration` branch, after `restore`, add:
```haskell
Rollbacks.storeRollbackPoint rollbackCol slot
    RollbackPoint { rpInverses = [], rpMeta = Nothing }
```

Remove `onBlock` parameter from `processBlock`.

**Done when**: `lib/` compiles.

---

### Task 1.2: Return checkpoint from `start`
**File**: `lib/ChainFollower/Runner.hs`

Add a helper:
```haskell
readCheckpoint :: RollbackCol -> T m cf col op (Maybe slot)
```

Uses `Rollbacks.queryTip` or iterates the rollback column to find the latest entry.

Change the way consumers initialize: `start` in `Init` stays as is (returns `Restoring`), but add a `readCheckpoint` export so the consumer can query it before starting the chain sync.

**Done when**: `lib/` compiles, `readCheckpoint` exported.

---

## Phase 2: Update callers

### Task 2.1: Remove `onBlock` from all call sites
**Files**: `test/RunnerSpec.hs`, `test/LifecycleSpec.hs`, `exe/Main.hs`, `lib/ChainFollower/Laws.hs`

Remove `(pure ())` arguments from all `processBlock` calls.

**Done when**: all files compile.

---

### Task 2.2: Add restart test
**File**: `test/RunnerSpec.hs`

New property: process N blocks in restoration, snapshot state, read checkpoint. Start a new session, read checkpoint, verify it matches slot N. Process remaining blocks, verify final state matches clean run.

**Done when**: new test passes.

---

### Task 2.3: Update tutorial
**Files**: `exe/Main.hs`, `tutorial/`

Tutorial narrative shows checkpoint being stored automatically. Remove manual checkpoint logic.

**Done when**: tutorial compiles and runs.

---

## Phase 3: CI

### Task 3.1: Format, lint, CI green
**Depends on**: 2.3

`just ci` passes.

**Done when**: CI clean.
