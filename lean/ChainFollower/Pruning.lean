import ChainFollower.SwapPartition
import ChainFollower.Rollback

/-!
# Pruning Proofs

Theorems proving that pruning the oldest entries from
the inverse log preserves rollback correctness for the
remaining (newest) entries.

## Main results

1. `applySwaps_append_invLog` — the inverse log of a
   concatenation is the concatenation of inverse logs
2. `partial_rollback_restores` — rolling back with only
   the suffix inverse log restores the intermediate state
3. `applySwaps_nonempty_invLog` — a non-empty operation
   list produces a non-empty inverse log
-/

-- ============================================================
-- Inverse log splits over concatenation
-- ============================================================

/-- The inverse log of `applySwaps s (xs ++ ys)` is the
    inverse log of `xs` followed by the inverse log of `ys`
    (applied to the intermediate state). -/
theorem applySwaps_append_invLog
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (xs ys : List (Binding κ α))
    : (applySwaps s (xs ++ ys)).2
    = (applySwaps s xs).2
      ++ (applySwaps (applySwaps s xs).1 ys).2 := by
  induction xs generalizing s with
  | nil => simp [applySwaps]
  | cons x xs ih =>
    simp only [List.cons_append, applySwaps]
    rw [ih (swap s x).1]

-- ============================================================
-- Partial rollback: suffix inverse log restores intermediate
-- ============================================================

/-- After applying `pre ++ suf` to state `s`,
    rolling back with only the suffix's inverse log
    restores the intermediate state (after applying
    just the prefix).

    This is the core pruning correctness theorem:
    discarding the oldest inverse entries (from the
    prefix) does not affect rollback within the
    suffix window. -/
theorem partial_rollback_restores
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (pre suf : List (Binding κ α))
    : let sMid := (applySwaps s pre).1
      let (sFinal, invSuffix) := applySwaps sMid suf
      rollback sFinal invSuffix = sMid := by
  simp only
  exact rollback_restores (applySwaps s pre).1 suf

-- ============================================================
-- Non-emptiness: non-empty ops yield non-empty inverse log
-- ============================================================

/-- If a suffix has at least one operation, its inverse
    log is non-empty. -/
theorem applySwaps_nonempty_invLog
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (ops : List (Binding κ α))
    (h : ops ≠ [])
    : (applySwaps s ops).2 ≠ [] := by
  match ops, h with
  | b :: bs, _ =>
    simp [applySwaps]

/-- The inverse log has the same length as the
    operation list. -/
theorem applySwaps_invLog_length
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (ops : List (Binding κ α))
    : (applySwaps s ops).2.length = ops.length := by
  induction ops generalizing s with
  | nil => simp [applySwaps]
  | cons b bs ih =>
    simp only [applySwaps, List.length_cons]
    rw [ih (swap s b).1]
