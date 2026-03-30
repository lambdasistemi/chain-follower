import ChainFollower.SwapPartition
import ChainFollower.Rollback

/-!
# Phase State Machine

Models the consumer lifecycle of the chain follower:

- **Restoring**: bulk ingestion, no inverse log, no rollback support
- **Following**: near tip, collects inverse log, supports rollback

## Consumer API

- `start nearTip` — enter initial phase
  - `nearTip = false` → `restoring` (wipe rollbacks)
  - `nearTip = true`  → `following` (keep existing rollbacks)
- `step atTip block phase state` — process one block
  - `restoring + false` → apply swap, stay restoring
  - `restoring + true`  → apply swap, transition to following
  - `following`         → apply swap, collect inverse

## Crash/restart

On crash, the consumer calls `start nearTip` again.
Far-from-tip restart wipes rollbacks → clean restoration.
Near-tip restart keeps rollbacks → resume following.

## Key theorems

1. **Transition transparency**: the state after processing
   blocks is the same regardless of where the transition happens
2. **Rollback bounded by transition**: inverse log only covers
   the following region
-/

/-- Phase of the chain follower. -/
inductive Phase (κ α : Type) where
  /-- Bulk ingestion: no inverse log. -/
  | restoring : Phase κ α
  /-- Near tip: collecting inverse log for rollback. -/
  | following : List (Binding κ α) → Phase κ α
  deriving Repr

/-- Process one block in the current phase.
    Returns (newPhase, newState).

    - `restoring + atTip=false`: apply swap, stay restoring
    - `restoring + atTip=true`: apply swap, start following
    - `following`: apply swap, collect inverse -/
def step
    {κ α : Type}
    [DecidableEq κ]
    (atTip : Bool)
    (b : Binding κ α)
    (phase : Phase κ α)
    (s : State κ α)
    : Phase κ α × State κ α :=
  let (s', inv) := swap s b
  match phase with
  | .restoring =>
    if atTip then
      (.following [inv], s')
    else
      (.restoring, s')
  | .following invLog =>
    (.following (inv :: invLog), s')

/-- Process a list of blocks, all with the same `atTip` value. -/
def stepMany
    {κ α : Type}
    [DecidableEq κ]
    (atTip : Bool)
    (phase : Phase κ α)
    (s : State κ α)
    : List (Binding κ α) → Phase κ α × State κ α
  | [] => (phase, s)
  | b :: bs =>
    let (phase', s') := step atTip b phase s
    stepMany atTip phase' s' bs

/-- Process a pre in restoration, then a suf in following.
    The transition happens on the first block of the suf. -/
def processWithTransition
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (pre : List (Binding κ α))
    (suf : List (Binding κ α))
    : Phase κ α × State κ α :=
  let (phase₁, s₁) := stepMany false .restoring s pre
  stepMany true phase₁ s₁ suf

-- ============================================================
-- Transition transparency
-- ============================================================

/-- The state component of `step` is always `(swap s b).1`,
    regardless of phase or atTip. -/
theorem step_state
    {κ α : Type}
    [DecidableEq κ]
    (atTip : Bool)
    (b : Binding κ α)
    (phase : Phase κ α)
    (s : State κ α)
    : (step atTip b phase s).2 = (swap s b).1 := by
  simp [step]
  split
  · split <;> simp_all
  · simp_all

/-- The state component of `stepMany` equals `applySwaps`. -/
theorem stepMany_state
    {κ α : Type}
    [DecidableEq κ]
    (atTip : Bool)
    (phase : Phase κ α)
    (s : State κ α)
    (ops : List (Binding κ α))
    : (stepMany atTip phase s ops).2
    = (applySwaps s ops).1 := by
  induction ops generalizing phase s with
  | nil => simp [stepMany, applySwaps]
  | cons b bs ih =>
    simp only [stepMany, applySwaps]
    rw [step_state]
    exact ih _ (swap s b).1

/-- **Transition transparency**: processing blocks with a
    transition at any split point produces the same final
    state as `applyBlocks` (= `applySwaps.1`) on the full
    sequence.

    The inverse log is a side output — it never affects
    the state. -/
theorem transition_transparency
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (pre suf : List (Binding κ α))
    : (processWithTransition s pre suf).2
    = (applySwaps s (pre ++ suf)).1 := by
  simp [processWithTransition]
  rw [stepMany_state, stepMany_state]
  exact (applySwaps_append_fst s pre suf).symm

-- ============================================================
-- Rollback bounded by transition
-- ============================================================

/-- stepMany with atTip=false and restoring stays restoring. -/
theorem stepMany_false_restoring
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (ops : List (Binding κ α))
    : (stepMany false .restoring s ops).1 = .restoring := by
  induction ops generalizing s with
  | nil => simp [stepMany]
  | cons b bs ih =>
    simp [stepMany, step]
    exact ih (swap s b).1

/-- stepMany with atTip=true from following accumulates
    inverses: the phase has invLog.length = old + ops.length. -/
theorem stepMany_true_following_length
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (invLog₀ : List (Binding κ α))
    (ops : List (Binding κ α))
    : ∃ invLog,
        (stepMany true (.following invLog₀) s ops).1
          = .following invLog
        ∧ invLog.length = invLog₀.length + ops.length := by
  induction ops generalizing s invLog₀ with
  | nil => exact ⟨invLog₀, rfl, by simp⟩
  | cons b bs ih =>
    simp [stepMany, step]
    have h := ih (swap s b).1 ((swap s b).2 :: invLog₀)
    obtain ⟨invLog, hPhase, hLen⟩ := h
    exact ⟨invLog, hPhase, by simp [List.length_cons] at hLen; omega⟩

/-- After restoration + transition, the inverse log
    contains only entries from the suf (following region).
    Its length equals the suf length. -/
theorem following_invLog_length
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (pre : List (Binding κ α))
    (suf : List (Binding κ α))
    : match (processWithTransition s pre suf).1 with
      | .following invLog => invLog.length = suf.length
      | .restoring => suf = [] := by
  induction suf generalizing s pre with
  | nil =>
    simp [processWithTransition, stepMany]
    induction pre generalizing s with
    | nil => simp [stepMany]
    | cons b bs ih =>
      simp [stepMany, step]
      exact ih (swap s b).1
  | cons b bs _ =>
    simp [processWithTransition]
    have hRes := stepMany_false_restoring s pre
    -- After restoration, phase is .restoring
    -- stepMany true .restoring s' (b :: bs):
    --   first step: step true b .restoring s' = (.following [inv], s'')
    --   rest: stepMany true (.following [inv]) s'' bs
    rw [show (stepMany false Phase.restoring s pre).1 = Phase.restoring
        from hRes]
    simp [stepMany, step]
    have h := stepMany_true_following_length
        (swap (stepMany false Phase.restoring s pre).2 b).1
        [(swap (stepMany false Phase.restoring s pre).2 b).2]
        bs
    obtain ⟨invLog, hPhase, hLen⟩ := h
    rw [hPhase]
    simp [List.length_cons] at hLen
    omega

/-- Rolling back the inverse log from following restores
    the state at the transition point. This connects to
    `partial_rollback_restores` from Pruning.lean. -/
theorem rollback_to_transition
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (pre suf : List (Binding κ α))
    : let sMid := (applySwaps s pre).1
      let (sFinal, invSuffix) := applySwaps sMid suf
      rollback sFinal invSuffix = sMid :=
  rollback_restores (applySwaps s pre).1 suf
