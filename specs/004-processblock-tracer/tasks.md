# Tasks: processBlock Tracer

## Task 1: Add contra-tracer dependency and define RunnerEvent

Add `contra-tracer` to `chain-follower.cabal` build-depends. Define `RunnerEvent slot` in `ChainFollower.Runner` and export it.

**Dependencies**: None

---

## Task 2: Add Tracer parameter to processBlock

Add `Tracer m (RunnerEvent slot)` as first parameter. Emit events in each branch. Update module exports.

**Dependencies**: Task 1

---

## Task 3: Update Laws.hs callers

Pass `nullTracer` to all `processBlock` calls in `runDfsWalk`, `runCanonical`, `prop_backendIsSwap`.

**Dependencies**: Task 2

---

## Task 4: Update test callers

Pass `nullTracer` to all `processBlock` calls in `RunnerSpec.hs`, `LifecycleSpec.hs`, `TransitionSpec.hs`.

**Dependencies**: Task 2

---

## Task 5: Add tracer event test

In `TransitionSpec.hs`, add a test that collects `RunnerEvent`s via an `IORef` tracer and asserts the correct sequence: `BlockRestored` × N, `PhaseTransition`, `BlockFollowed` × M.

**Dependencies**: Task 4
