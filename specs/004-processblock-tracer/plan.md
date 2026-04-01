# Implementation Plan: processBlock Tracer

**Branch**: `004-processblock-tracer` | **Date**: 2026-04-01 | **Spec**: `specs/004-processblock-tracer/spec.md`

## Summary

Add a `Tracer IO (RunnerEvent slot)` parameter to `processBlock` so phase transitions and block processing are observable. Define `RunnerEvent` as a sum type in `ChainFollower.Runner`.

## Technical Context

**Language/Version**: Haskell (GHC 9.8.4)
**New dependency**: `contra-tracer` (add to chain-follower.cabal)
**Testing**: hspec — verify tracer captures events via IORef collector

## Constitution Check

All gates pass. No new invariants — this is observability, not behavior change.

## Implementation Approach

### 1. Define RunnerEvent

In `ChainFollower.Runner`:

```haskell
data RunnerEvent slot
    = BlockRestored slot        -- block processed in restoration
    | BlockFollowed slot        -- block processed in following
    | PhaseTransition slot      -- InRestoration → InFollowing at this slot
    deriving (Show, Eq)
```

### 2. Add Tracer to processBlock

Add `Tracer m (RunnerEvent slot)` as the first parameter. Emit:
- `BlockRestored slot` in the `InRestoration + atTip=False` branch
- `PhaseTransition slot` then `BlockFollowed slot` in the `InRestoration + atTip=True` branch
- `BlockFollowed slot` in the `InFollowing` branch

### 3. Update all callers

- `ChainFollower.Laws` — `runDfsWalk`, `runCanonical`, `prop_backendIsSwap` pass `nullTracer`
- `test/RunnerSpec.hs` — `runChainEvents`, `runCanonicalClean`, `runChainEventsWithPruning` pass `nullTracer`
- `test/LifecycleSpec.hs` — all `processBlock` calls pass `nullTracer`
- `test/TransitionSpec.hs` — `restoreBlocks`, `followBlocks` pass `nullTracer`; the observer test uses a collecting tracer

### 4. Add tracer test in TransitionSpec

Use an `IORef [RunnerEvent SlotNo]` as a collecting tracer. Verify:
- Restoration blocks emit `BlockRestored`
- Transition emits `PhaseTransition`
- Following blocks emit `BlockFollowed`
