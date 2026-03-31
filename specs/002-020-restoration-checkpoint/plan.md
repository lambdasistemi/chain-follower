# Implementation Plan: Restoration Checkpoint in Runner

**Branch**: `feat/restoration-checkpoint` | **Date**: 2026-03-31 | **Spec**: [spec.md](spec.md)

## Research Summary

### Current State

- `armageddonSetup` stores a sentinel rollback point (empty inverses, no metadata) in the rollback column
- In following mode, rollback points accumulate after the sentinel
- In restoration mode, no rollback points are written — no resume mechanism
- Consumers manually checkpoint via `onBlock` callback

### Design: Reuse Rollback Column

The checkpoint during restoration is just the sentinel rollback point, updated to the current slot after each block. No new column needed.

During restoration, `processBlock` writes:
```
storeRollbackPoint rollbackCol currentSlot (RollbackPoint [] Nothing)
```

This overwrites the previous checkpoint — the rollback column always has exactly one entry during restoration (the sentinel/checkpoint at the latest slot).

On transition to following, the checkpoint is already in the rollback column as the base. New rollback points accumulate after it. Seamless.

On `start`, the Runner reads the rollback column tip to find the checkpoint. If empty, start from origin.

### What changes

1. `processBlock` in `InRestoration`: after `restore`, store a checkpoint rollback point
2. `start` in `Init`: return the checkpoint slot (read from rollback column)
3. `onBlock` callback: no longer needed for checkpoint — can be removed or kept for other uses
4. No new column, no new types

### What about `onBlock`

Since the checkpoint is now internal, `onBlock` loses its primary purpose. We can:
- Remove it (breaking change, simpler API)
- Keep it (backward compatible, consumers can still hook in)

**Decision**: Remove it. It was added specifically for checkpoints. If consumers need per-block hooks, they can add them in their own `rollForward`.

## Implementation Phases

### Phase 1: Store checkpoint in restoration

**File**: `lib/ChainFollower/Runner.hs`

In `InRestoration` branch of `processBlock`, after `restore`:
```haskell
Rollbacks.storeRollbackPoint rollbackCol slot
    RollbackPoint { rpInverses = [], rpMeta = Nothing }
```

Remove `onBlock` parameter from `processBlock`.

### Phase 2: Return checkpoint from `start`

**File**: `lib/ChainFollower/Runner.hs`, `lib/ChainFollower/Backend.hs`

Change `Init.start` to take a transaction runner and rollback column, read the tip of the rollback column, return `(Maybe slot, Restoring ...)`.

### Phase 3: Update tests and tutorial

Remove `onBlock` from all call sites. Add restart test verifying checkpoint.

## Risk Assessment

- **Breaking**: `processBlock` loses `onBlock`, `start` gains parameters and return value
- **Simple**: No new types, no new columns — just one `storeRollbackPoint` call per block in restoration
