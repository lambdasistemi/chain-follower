# Tasks: Restoration→Following Phase Transition

**Feature**: 001-018-phase-transition
**Plan**: [plan.md](plan.md)

## Phase 1: Lean — Phase State Machine

### Task 1.1: Define Phase state machine
**File**: `lean/ChainFollower/Phase.lean`
**Depends on**: nothing

Define:
- `Phase`: `restoring` | `following (invLog depth)`
- `start (nearTip : Bool)`: returns initial phase
- `processBlock (atTip : Bool) (block) (phase) (state)`: state transition
  - `restoring` + `False`: apply swap, no inverse, stay `restoring`
  - `restoring` + `True`: apply swap, switch to `following` (start collecting inverses)
  - `following`: apply swap, collect inverse, prune if beyond window
- `crash`: phase → crash state (captures what's on disk)
- `restart (nearTip : Bool)`: crash state → phase (wipe rollbacks if far, keep if near)

**Done when**: definitions compile.

---

### Task 1.2: Prove transition transparency
**File**: `lean/ChainFollower/Phase.lean`
**Depends on**: 1.1

For a fork-free block sequence, processing with a transition at any split point produces the same final state as `applyBlocks` on the full sequence. The swap is the same in both phases — the inverse log is a side output.

**Done when**: `transition_transparency` compiles with no `sorry`.

---

### Task 1.3: Prove fork confinement
**File**: `lean/ChainFollower/Phase.lean`
**Depends on**: 1.1

For a well-formed tree with stability window k, the DFS walk has no rollback events in the first `depth - k` blocks. Connect to existing `wellFormed` and `dfs` definitions in `BlockTree.lean`.

**Done when**: `fork_confinement` compiles with no `sorry`.

---

### Task 1.4: Prove restart near tip preserves rollbacks
**File**: `lean/ChainFollower/Phase.lean`
**Depends on**: 1.1

After crash in following + restart with `nearTip=True`, the existing inverse log is still valid (state determinism — the state at each slot is the same regardless of how we got there).

**Done when**: `restart_near_preserves` compiles with no `sorry`.

---

### Task 1.5: Prove state determinism across crashes
**File**: `lean/ChainFollower/Phase.lean`
**Depends on**: 1.2, 1.3, 1.4

The main theorem: for any crash pattern (sequence of runs with crashes at arbitrary points), the final state after processing the full canonical chain is the same.

**Done when**: `state_determinism` compiles with no `sorry`.

---

### Task 1.6: Import and build
**File**: `lean/ChainFollower.lean`
**Depends on**: 1.5

Add `import ChainFollower.Phase`. `lake build` succeeds.

**Done when**: `lake build` green.

---

## Phase 2: Haskell — Runner and Backend

### Task 2.1: Change `Init` to single `start` with `Bool`
**File**: `lib/ChainFollower/Backend.hs`
**Depends on**: 1.6

```haskell
newtype Init m t block inv meta = Init
    { start :: Bool -> m (Phase ...) }
```

Backend internally keeps `startRestoring` / `resumeFollowing` — the Runner wraps them:
- `False`: crash recovery, wipe rollbacks, `startRestoring` → `InRestoration`
- `True`: crash recovery (finish replay), `resumeFollowing` → `InFollowing`

Update `liftInit`.

**Done when**: `lib/` compiles.

---

### Task 2.2: Change `processBlock` to return in `m`
**File**: `lib/ChainFollower/Runner.hs`
**Depends on**: 2.1

```haskell
processBlock
    :: Bool -> (forall a. T ... a -> m a)
    -> RollbackCol -> Int -> slot -> block -> Phase -> m Phase
```

- `InRestoration` + `False`: `runTx (restore ...)`, stay `InRestoration`
- `InRestoration` + `True`: `runTx (restore ...)`, `toFollowing` in `m`, `InFollowing`
- `InFollowing`: `runTx (follow + store + prune)`, `InFollowing`

**Done when**: `lib/` compiles.

---

### Task 2.3: Update tutorial
**Files**: `tutorial/TutorialDB.hs`, `tutorial/Composed.hs`, `exe/Main.hs`
**Depends on**: 2.2

Adapt to new `Init` and `processBlock` signatures.

**Done when**: tutorial compiles and runs.

---

## Phase 3: Tests and CI

### Task 3.1: Adapt existing tests
**File**: `test/RunnerSpec.hs`
**Depends on**: 2.3

- `runChainEvents` starts via `start False` → `InRestoration`, transitions to following when processing last blocks
- `runCanonicalClean` uses restoration only
- Existing properties (DFS≡canonical, fork resolution, rollback within window) pass

**Done when**: existing tests pass.

---

### Task 3.2: Add crash/restart properties
**File**: `test/RunnerSpec.hs`
**Depends on**: 3.1

New properties:
1. Near-tip restart keeps rollback points valid
2. Far-from-tip restart + wipe produces same result as fresh start
3. Rollback to pre-transition slot → `RollbackImpossible`
4. Immediate transition (`atTip=True` from block 1) ≡ following-only

**Done when**: all new properties pass.

---

### Task 3.3: CI green
**Depends on**: 3.2

`just ci` passes: fourmolu, hlint, cabal-check, build, test, lake build.

**Done when**: CI clean.
