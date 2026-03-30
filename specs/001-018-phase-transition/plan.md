# Implementation Plan: Restoration→Following Phase Transition

**Branch**: `feat/phase-transition` | **Date**: 2026-03-30 | **Spec**: [spec.md](spec.md)

## Research Summary

### Current State

- `processBlock` dispatches on `Phase` but never transitions
- `Init` has two fields (`startRestoring` / `resumeFollowing`) — forces consumer to choose
- All tests start in `InFollowing`, restoration and transition are untested
- Lean model proves swap/rollback/pruning but doesn't model phases or crash/restart

### Consumer API

One entry point, one bit of information:

```haskell
newtype Init m t block inv meta = Init
    { start :: Bool -> m (Phase ...) }
    -- Bool = nearTip
```

The consumer calls `start nearTip` on every (re)start. The Runner decides:

- `nearTip = True` → finish replay if incomplete, keep rollback points, enter `InFollowing`
- `nearTip = False` → recover crash if needed, wipe rollback points, enter `InRestoration`

Then `processBlock atTip` per block:

- `InRestoration` + `atTip = False` → stay in restoration
- `InRestoration` + `atTip = True` → replay journal (toFollowing), switch to `InFollowing`
- `InFollowing` → stay in following (regardless of `atTip`)

### Crash/Restart Analysis

**Case 1: Crash in Restoration, restart far from tip**
- `start False` → recover, wipe rollbacks (already empty), enter restoration
- Resume from checkpoint. Trivial.

**Case 2: Crash in Following, restart near tip**
- `start True` → finish replay if needed (no incomplete replay here — was in following), keep rollback points, enter following
- Existing rollback points are valid — state at those slots is deterministic
- Resume following normally.

**Case 3: Crash in Following, restart far from tip**
- `start False` → recover, wipe rollback points, enter restoration
- Old inverses discarded. Process blocks in restoration until tip.
- Transition to following with fresh rollback points. Clean.

**Case 4: Crash during Replay (toFollowing), restart near tip**
- `start True` → MTS crash recovery finishes the replay, enter following
- Rollback points from before the crash are still valid (replay doesn't change the KV state, only builds CSMT tree)
- Resume following normally.

**Case 5: Crash during Replay, restart far from tip**
- `start False` → MTS crash recovery (any direction — doesn't matter), wipe rollbacks, enter restoration
- Will redo everything from checkpoint. Clean.

### Key Invariants

1. **State determinism**: the KV state at any slot is the same regardless of crash pattern (swaps are deterministic)
2. **Rollback validity**: inverses computed at slot X are valid whenever the state at slot X is the same — guaranteed by determinism
3. **Replay doesn't mutate KV state**: replay only builds the CSMT tree from the journal — KV state and rollback point inverses are unaffected
4. **Wipe on far-from-tip restart**: eliminates all reasoning about mixed old/new rollback sets

### Lean Formalization Strategy

Model the consumer lifecycle:

```
Phase = Restoring | Replaying | Following(invLog, depth)

start : Bool → Phase
processBlock : Bool → Block → Phase → State → Phase × State
crash : Phase → CrashState
restart : Bool → CrashState → Phase
```

The block tree resolves over time — old forks collapse into the canonical prefix:

- Restoration consumes the resolved (fork-free) prefix
- Following consumes the unresolved suffix (forks within stability window k)

Theorems:

1. **Transition transparency**: for a fork-free block sequence, restoration and following produce the same state
2. **Fork confinement**: in a well-formed tree with window k, all forks are within k of tip
3. **Restart near tip preserves rollbacks**: existing inverses remain valid because state is deterministic
4. **Restart far from tip + wipe is clean**: equivalent to fresh start
5. **Replay completion on near-tip restart**: finishing an interrupted replay produces the same result as a clean replay
6. **State determinism across any crash pattern**: final state depends only on the canonical chain

## Implementation Phases

### Phase 1: Lean — Phase state machine with crash/restart

**File**: `lean/ChainFollower/Phase.lean`

Define Phase, start, processBlock, crash, restart. Prove all 6 theorems above.

### Phase 2: Haskell — Runner and Backend

**Files**: `lib/ChainFollower/Backend.hs`, `lib/ChainFollower/Runner.hs`

1. `Init` becomes `newtype Init ... = Init { start :: Bool -> m (Phase ...) }`
   - `start False`: crash recovery, wipe rollbacks, call `startRestoring`, return `InRestoration`
   - `start True`: crash recovery (finish replay), call `resumeFollowing`, return `InFollowing`
2. `processBlock` takes `Bool` (atTip) + transaction runner, returns in `m`
3. Backend keeps both `startRestoring` and `resumeFollowing` internally — Runner wraps them
4. Update `liftInit`

### Phase 3: Tutorial, tests, CI

**Files**: `tutorial/`, `test/RunnerSpec.hs`

1. Tutorial adapts to new `Init`
2. Tests cover: fresh start (restoration→following), near-tip restart, far-from-tip restart
3. Existing DFS≡canonical property adapted to start in restoration
4. New properties for each crash/restart case
5. `just ci` green
