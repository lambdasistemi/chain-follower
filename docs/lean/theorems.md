# Theorems Reference

Exhaustive listing of all theorems in the Lean formalization.

## Summary

| Theorem | File | Property |
|---|---|---|
| `applySwaps_append_fst` | SwapPartition | `applySwaps` distributes over list concatenation |
| `swap_inverse_restores` | Rollback | swap then swap-back = identity (pointwise) |
| `swap_inverse_binding` | Rollback | displaced binding round-trips to the original |
| `single_step_rollback` | Rollback | one swap then undo = original state |
| `rollback_restores` | Rollback | multi-step rollback via reversed inverse log |
| `state_total` | Rollback | state is a total function (by construction) |
| `swap_preserves_totality` | Rollback | swap preserves totality |
| `swap_commute` | Rollback | swaps at different keys commute |
| `List.sizeOf_last'_le` | BlockTree | termination helper for `canonical` |
| `goFull_dfsSubtree` | BlockTree | core inductive lemma (state + stack + undo) |
| `dfs_equiv_canonical` | BlockTree | DFS walk = canonical path (main theorem) |

---

## SwapPartition.lean

Source: [`SwapPartition.lean`][swap-src]

[swap-src]: https://github.com/lambdasistemi/chain-follower/blob/feat/rollback-support/lean/ChainFollower/SwapPartition.lean

### `applySwaps_append_fst`

**Property**: applying swaps over a concatenated list equals applying the first
list then the second (for the state component).

```lean
theorem applySwaps_append_fst
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (xs ys : List (Binding κ α))
    : (applySwaps s (xs ++ ys)).1
    = (applySwaps (applySwaps s xs).1 ys).1
```

This is a structural lemma required by the induction step of `rollback_restores`.
It says that `applySwaps` is compositional: processing `xs ++ ys` is the same as
processing `xs` first, then `ys` from the resulting state.

---

## Rollback.lean

Source: [`Rollback.lean`][rb-src]

[rb-src]: https://github.com/lambdasistemi/chain-follower/blob/feat/rollback-support/lean/ChainFollower/Rollback.lean

### `swap_inverse_restores`

**Property**: swapping a binding into the state and then swapping the displaced
binding back restores the original state at every key.

```lean
theorem swap_inverse_restores
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (b : Binding κ α)
    : let (s', inv) := swap s b
      let (s'', _) := swap s' inv
      ∀ (k : κ), s'' k = s k
```

The fundamental involution property. Every swap carries its own inverse: the
displaced binding. This is the core reason rollback works at all.

### `swap_inverse_binding`

**Property**: the displaced binding, when swapped back, produces the original
binding as its own displaced output.

```lean
theorem swap_inverse_binding
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (b : Binding κ α)
    : let (s', inv) := swap s b
      let (_, inv') := swap s' inv
      inv' = b
```

This says that the inverse of the inverse is the original. Together with
`swap_inverse_restores`, it establishes that swap is a perfect involution on
both the state and the binding.

### `single_step_rollback`

**Property**: after one swap, applying the inverse restores the state (function
extensionality, not just pointwise).

```lean
theorem single_step_rollback
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (b : Binding κ α)
    : let (s', inv) := swap s b
      (swap s' inv).1 = s
```

Lifts `swap_inverse_restores` from pointwise equality (`forall k, ...`) to
propositional equality of functions via `funext`. This is the form needed by
downstream proofs.

### `rollback_restores`

**Property**: applying a sequence of swaps and then rolling back with the
inverse log (reversed) restores the original state.

```lean
theorem rollback_restores
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (ops : List (Binding κ α))
    : let (s', invLog) := applySwaps s ops
      rollback s' invLog = s
```

The main correctness theorem for the rollback mechanism in isolation. For any
sequence of mutations, the collected inverse log is sufficient to restore the
original state when replayed in reverse. The proof proceeds by induction on
`ops`, using `applySwaps_append_fst` for the cons case and
`single_step_rollback` for the base.

### `state_total`

**Property**: the state maps every key to exactly one value.

```lean
theorem state_total
    {κ α : Type}
    (s : State κ α)
    (k : κ)
    : ∃ (v : Val α), s k = v
```

Trivially true by construction (the state is a total function), but stated
explicitly to document the conservation invariant: `|S| = |Keys|` always holds.

### `swap_preserves_totality`

**Property**: after a swap, the resulting state still maps every key to exactly
one value.

```lean
theorem swap_preserves_totality
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (b : Binding κ α)
    (k : κ)
    : ∃ (v : Val α), (swap s b).1 k = v
```

Again trivial by construction, but documents that swap does not break totality.
In a model with partial maps this would be non-trivial.

### `swap_commute`

**Property**: swaps at distinct keys commute -- order does not matter when
operating on different keys.

```lean
theorem swap_commute
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (b₁ b₂ : Binding κ α)
    (h : b₁.key ≠ b₂.key)
    : let (s₁, _) := swap s b₁
      let (s₂, _) := swap s₁ b₂
      let (t₁, _) := swap s b₂
      let (t₂, _) := swap t₁ b₁
      ∀ (k : κ), s₂ k = t₂ k
```

Not used in the main proof chain, but establishes an important property: swaps
to independent keys are non-interfering. This justifies reasoning about
per-key rollback independently.

---

## BlockTree.lean

Source: [`BlockTree.lean`][bt-src]

[bt-src]: https://github.com/lambdasistemi/chain-follower/blob/feat/rollback-support/lean/ChainFollower/BlockTree.lean

### `List.sizeOf_last'_le`

**Property**: the `sizeOf` the last element of a list is bounded by the sum of
the seed element's size and the list's size.

```lean
theorem List.sizeOf_last'_le {α : Type} [SizeOf α]
    (x : α) (xs : List α)
    : sizeOf (List.last' x xs) ≤ sizeOf x + sizeOf xs
```

A termination helper. The `canonical` function recurses into `List.last'` of the
children list. Lean's termination checker needs this bound to verify that the
recursive argument is structurally smaller.

### `goFull_dfsSubtree`

**Property**: processing a subtree's DFS walk from state `s` with stack `stack`
yields three things simultaneously:

1. The final state equals `applyBlocks s (canonical t)`.
2. The stack has the form `newEntries ++ stack` where all new entries have
   slots greater than the bound.
3. `undoTo` at the bound restores `(s, stack)` exactly.

```lean
theorem goFull_dfsSubtree
    {κ α : Type}
    [DecidableEq κ]
    (t : BlockTree κ α)
    (s : State κ α)
    (stack : List (Nat × Binding κ α))
    (bound : Nat)
    (hSlots : allSlotsGt bound t)
    (hOrd : slotsOrdered t)
    (hStack : ∀ p ∈ stack, p.1 ≤ bound)
    : (goFull s stack (dfsSubtree t)).1
      = applyBlocks s (canonical t)
    ∧ (∃ newEntries : List (Nat × Binding κ α),
        (goFull s stack (dfsSubtree t)).2
        = newEntries ++ stack
        ∧ stackSlotsGt bound newEntries)
    ∧ processEvents.undoTo
        (goFull s stack (dfsSubtree t)).1
        (goFull s stack (dfsSubtree t)).2
        bound
      = (s, stack)
```

This is the core of the entire formalization. The three conjuncts must be proved
together because the induction hypothesis for the multi-child case
(`goFull_interleaveRollbacks`) requires all three: you cannot prove state
correctness without knowing the stack shape, and you cannot prove stack shape
without knowing rollback works.

The proof proceeds by structural induction on the tree, with cases for leaf,
single-child fork, and multi-child fork. The multi-child case delegates to
`goFull_interleaveRollbacks`, which shows that each non-rightmost child's DFS
followed by a rollback is a no-op.

!!! note
    Preconditions `allSlotsGt` and `slotsOrdered` correspond to the blockchain
    invariant that slot numbers increase monotonically from parent to child.
    Without this, `undoTo` could not correctly identify which stack entries to
    pop.

### `dfs_equiv_canonical`

**Property**: for any well-formed block tree, processing the full DFS walk
produces the same state as applying only the canonical (rightmost) path.

```lean
theorem dfs_equiv_canonical
    {κ α : Type}
    [DecidableEq κ]
    (t : BlockTree κ α)
    (k : Nat)
    (_wf : wellFormed k t)
    (s : State κ α)
    (hSlots : allSlotsGt 0 t)
    (hOrd : slotsOrdered t)
    : processEvents s (dfs t)
    = applyBlocks s (canonical t)
```

The main theorem. It is a one-line corollary of `goFull_dfsSubtree`: unfold
`dfs` and `processEvents`, rewrite via `go_eq_goFull_fst`, and extract the
first conjunct.

This theorem says: no matter how many forks the follower traverses, the final
state depends only on the canonical chain. The journey through dead-end branches
is perfectly undone by the rollback mechanism.
