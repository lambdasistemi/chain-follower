import ChainFollower.SwapPartition
import ChainFollower.Rollback

/-!
# Block Tree and DFS Walk

A blockchain with forks is modeled as a rose tree.
The chain follower sees a deterministic left-to-right
DFS traversal. The canonical chain is the rightmost path.

## Key types

- `BlockTree` — rose tree of blocks, children ordered
  left (first explored) to right (canonical)
- `ChainEvent` — what the follower sees: Forward or RollBack
- `dfs` — the unique DFS walk through the tree
- `canonical` — the rightmost path (final chain)

## Stability window

All non-rightmost branches must have depth ≤ K (the
stability window). This is a structural constraint from
the consensus protocol: forks can't exceed K blocks.

## Main theorem

For any well-formed tree, processing the DFS walk
produces the same state as processing the canonical
chain directly.
-/

/-- A block: slot number + a binding (the mutation). -/
structure Block (κ α : Type) where
  slot : Nat
  binding : Binding κ α
  deriving DecidableEq, Repr

/-- A rose tree of blocks. Children are ordered:
    leftmost = first explored, rightmost = canonical. -/
inductive BlockTree (κ α : Type) where
  | leaf : Block κ α → BlockTree κ α
  | fork : Block κ α → List (BlockTree κ α) → BlockTree κ α
  deriving Repr

/-- What the chain follower observes. -/
inductive ChainEvent (κ α : Type) where
  | forward : Block κ α → ChainEvent κ α
  | rollBack : Nat → ChainEvent κ α
  deriving Repr

-- ============================================================
-- Tree operations
-- ============================================================

/-- The block at the root of a tree. -/
def BlockTree.root {κ α : Type}
    : BlockTree κ α → Block κ α
  | .leaf b => b
  | .fork b _ => b

/-- Depth of a tree. -/
def BlockTree.depth {κ α : Type}
    : BlockTree κ α → Nat
  | .leaf _ => 1
  | .fork _ children =>
    1 + (children.map BlockTree.depth).foldl max 0

/-- Get the last element of a non-empty list. -/
def List.last' {α : Type} : α → List α → α
  | x, [] => x
  | _, y :: ys => List.last' y ys

/-- last' picks from the list, so its size is bounded. -/
theorem List.sizeOf_last'_le {α : Type} [SizeOf α]
    (x : α) (xs : List α)
    : sizeOf (List.last' x xs) ≤ sizeOf x + sizeOf xs := by
  induction xs generalizing x with
  | nil => simp [List.last']
  | cons y ys ih =>
    simp only [List.last']
    have h := ih y
    simp only [List.cons.sizeOf_spec]
    omega

/-- The rightmost (canonical) path from root to leaf. -/
def canonical {κ α : Type}
    : BlockTree κ α → List (Block κ α)
  | .leaf b => [b]
  | .fork b [] => [b]
  | .fork b (c :: cs) =>
    b :: canonical (List.last' c cs)
termination_by t => sizeOf t
decreasing_by
  simp_wf
  have h := List.sizeOf_last'_le c cs
  omega

-- ============================================================
-- DFS walk
-- ============================================================

/-- DFS walk of a single subtree: forward the root,
    then recurse into children left-to-right.
    Between non-rightmost children, emit a rollBack
    to the current root's slot. -/
def dfsSubtree {κ α : Type}
    : BlockTree κ α → List (ChainEvent κ α)
  | .leaf b => [.forward b]
  | .fork b children =>
    let fwd := ChainEvent.forward b
    let childWalks := children.map dfsSubtree
    fwd :: interleaveRollbacks b.slot childWalks
where
  /-- Interleave rollbacks between child walks.
      After each non-last child, add a rollBack. -/
  interleaveRollbacks (slot : Nat)
      : List (List (ChainEvent κ α))
      → List (ChainEvent κ α)
    | [] => []
    | [w] => w
    | w :: ws =>
      w ++ [.rollBack slot]
        ++ interleaveRollbacks slot ws

/-- The full DFS walk of a tree. -/
def dfs {κ α : Type}
    (t : BlockTree κ α)
    : List (ChainEvent κ α) :=
  dfsSubtree t

-- ============================================================
-- Well-formedness: stability window
-- ============================================================

/-- A tree is well-formed w.r.t. stability window K
    if every non-rightmost subtree has depth ≤ K. -/
def wellFormed {κ α : Type}
    (k : Nat)
    : BlockTree κ α → Prop
  | .leaf _ => True
  | .fork _ [] => True
  | .fork _ children =>
    -- All non-rightmost children have depth ≤ k
    let nonRightmost := children.dropLast
    (∀ c ∈ nonRightmost, BlockTree.depth c ≤ k)
    -- Recursively well-formed
    ∧ (∀ c ∈ children, wellFormed k c)

-- ============================================================
-- State machine: processing events
-- ============================================================

/-- Apply a single block to the state (one swap). -/
def applyBlock {κ α : Type} [DecidableEq κ]
    (s : State κ α) (b : Block κ α)
    : State κ α :=
  (swap s b.binding).1

/-- Apply a list of blocks to the state. -/
def applyBlocks {κ α : Type} [DecidableEq κ]
    (s : State κ α) : List (Block κ α) → State κ α
  | [] => s
  | b :: bs => applyBlocks (applyBlock s b) bs

/-- Process chain events with rollback support.
    Maintains a stack of (slot, inverseLog) pairs.
    Forward: apply block, push inverse.
    RollBack: pop and undo until reaching target slot. -/
def processEvents {κ α : Type} [DecidableEq κ]
    (s : State κ α)
    (events : List (ChainEvent κ α))
    : State κ α :=
  go s [] events
where
  go (s : State κ α)
     (stack : List (Nat × Binding κ α))
     : List (ChainEvent κ α) → State κ α
    | [] => s
    | .forward b :: rest =>
      let (s', inv) := swap s b.binding
      go s' ((b.slot, inv) :: stack) rest
    | .rollBack target :: rest =>
      let (s', stack') := undoTo s stack target
      go s' stack' rest
  undoTo (s : State κ α)
      (stack : List (Nat × Binding κ α))
      (target : Nat)
      : State κ α × List (Nat × Binding κ α) :=
    match stack with
    | [] => (s, [])
    | (slot, inv) :: rest =>
      if slot > target then
        let (s', _) := swap s inv
        undoTo s' rest target
      else
        (s, stack)

-- ============================================================
-- Slot ordering: all blocks in a subtree have slot > parent
-- ============================================================

/-- All block slots in a tree are > the given bound. -/
def allSlotsGt {κ α : Type}
    (bound : Nat) : BlockTree κ α → Prop
  | .leaf b => b.slot > bound
  | .fork b children =>
    b.slot > bound ∧ ∀ c ∈ children, allSlotsGt b.slot c

/-- Slot ordering: parent slot < all descendant slots. -/
def slotsOrdered {κ α : Type}
    : BlockTree κ α → Prop
  | .leaf _ => True
  | .fork b children =>
    (∀ c ∈ children, allSlotsGt b.slot c)
    ∧ (∀ c ∈ children, slotsOrdered c)

-- ============================================================
-- Helper definitions and lemmas
-- ============================================================

/-- Version of `processEvents.go` that returns both the final
    state and the final stack. -/
def goFull
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (stack : List (Nat × Binding κ α))
    : List (ChainEvent κ α)
    → State κ α × List (Nat × Binding κ α)
  | [] => (s, stack)
  | .forward b :: rest =>
    let (s', inv) := swap s b.binding
    goFull s' ((b.slot, inv) :: stack) rest
  | .rollBack target :: rest =>
    let (s', stack') := processEvents.undoTo s stack target
    goFull s' stack' rest

/-- `processEvents.go` equals the first component of `goFull`. -/
theorem go_eq_goFull_fst
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (stack : List (Nat × Binding κ α))
    (es : List (ChainEvent κ α))
    : processEvents.go s stack es
    = (goFull s stack es).1 := by
  induction es generalizing s stack with
  | nil => simp [processEvents.go, goFull]
  | cons e es ih =>
    cases e with
    | forward b =>
      simp only [processEvents.go, goFull]; exact ih _ _
    | rollBack target =>
      simp only [processEvents.go, goFull]; exact ih _ _

/-- `goFull` over appended event lists. -/
theorem goFull_append
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (stack : List (Nat × Binding κ α))
    (es₁ es₂ : List (ChainEvent κ α))
    : goFull s stack (es₁ ++ es₂)
    = let r := goFull s stack es₁
      goFull r.1 r.2 es₂ := by
  induction es₁ generalizing s stack with
  | nil => simp [goFull]
  | cons e es₁ ih =>
    cases e with
    | forward b =>
      simp only [List.cons_append, goFull]; exact ih _ _
    | rollBack target =>
      simp only [List.cons_append, goFull]; exact ih _ _

/-- `applyBlocks` over cons. -/
theorem applyBlocks_cons
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (b : Block κ α)
    (bs : List (Block κ α))
    : applyBlocks s (b :: bs)
    = applyBlocks (applyBlock s b) bs := by
  simp [applyBlocks]

-- ============================================================
-- undoTo lemmas
-- ============================================================

/-- `undoTo` on empty stack. -/
theorem undoTo_nil
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (target : Nat)
    : processEvents.undoTo s [] target = (s, []) := by
  simp [processEvents.undoTo]

/-- `undoTo` pops when slot > target. -/
theorem undoTo_pop
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (slot : Nat)
    (inv : Binding κ α)
    (rest : List (Nat × Binding κ α))
    (target : Nat)
    (h : slot > target)
    : processEvents.undoTo s ((slot, inv) :: rest) target
    = processEvents.undoTo (swap s inv).1 rest target := by
  simp [processEvents.undoTo, h]

/-- `undoTo` stops when slot ≤ target. -/
theorem undoTo_stop
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (slot : Nat)
    (inv : Binding κ α)
    (rest : List (Nat × Binding κ α))
    (target : Nat)
    (h : ¬(slot > target))
    : processEvents.undoTo s ((slot, inv) :: rest) target
    = (s, (slot, inv) :: rest) := by
  simp [processEvents.undoTo, h]

/-- `undoTo` on a stack where all slots ≤ target is a no-op. -/
theorem undoTo_all_below
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (stack : List (Nat × Binding κ α))
    (target : Nat)
    (h : ∀ p ∈ stack, p.1 ≤ target)
    : processEvents.undoTo s stack target
    = (s, stack) := by
  cases stack with
  | nil => simp [processEvents.undoTo]
  | cons p rest =>
    have hp := h p (by simp)
    have : ¬(p.1 > target) := by omega
    cases p with
    | mk slot inv => exact undoTo_stop s slot inv rest target this

-- ============================================================
-- Key lemma: goFull on dfsSubtree
-- ============================================================

/-- Helper: all slots in the stack produced by processing
    a subtree's DFS are ≥ some bound. -/
def stackSlotsGt
    (bound : Nat)
    {κ α : Type}
    (stack : List (Nat × Binding κ α))
    : Prop :=
  ∀ p ∈ stack, p.1 > bound

theorem stackSlotsGt_nil
    {κ α : Type}
    (bound : Nat)
    : stackSlotsGt bound (κ := κ) (α := α) [] := by
  intro p hp; simp at hp

theorem stackSlotsGt_cons
    {κ α : Type}
    (bound slot : Nat)
    (inv : Binding κ α)
    (rest : List (Nat × Binding κ α))
    (hs : slot > bound)
    (hr : stackSlotsGt bound rest)
    : stackSlotsGt bound ((slot, inv) :: rest) := by
  intro p hp
  simp only [List.mem_cons] at hp
  cases hp with
  | inl h => subst h; exact hs
  | inr h => exact hr p h

/-- `undoTo` on a stack where all entries have slot > target
    pops everything and restores state via rollback. -/
theorem undoTo_all_above_restores
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (newStack : List (Nat × Binding κ α))
    (origStack : List (Nat × Binding κ α))
    (target : Nat)
    (hSlots : stackSlotsGt target newStack)
    (hOrig : ∀ p ∈ origStack, p.1 ≤ target)
    : processEvents.undoTo s (newStack ++ origStack) target
    = ( (applySwaps s
          (newStack.map Prod.snd)).1
      , origStack) := by
  induction newStack generalizing s with
  | nil =>
    simp [applySwaps]
    exact undoTo_all_below s origStack target hOrig
  | cons p rest ih =>
    cases p with
    | mk slot inv =>
      have hgt : slot > target :=
        hSlots (slot, inv) (by simp)
      simp only [List.cons_append]
      rw [undoTo_pop s slot inv (rest ++ origStack) target hgt]
      have hrest : stackSlotsGt target rest := by
        intro q hq
        exact hSlots q (by simp [hq])
      rw [ih (swap s inv).1 hrest]
      simp [applySwaps]

/-- `undoTo` can be split: if undoTo at target₁ gives
    (s₁, stack₁), and then undoTo at target₂ ≤ target₁
    on (s₁, stack₁) gives (s₂, stack₂), then undoTo at
    target₂ on the original gives (s₂, stack₂). -/
theorem undoTo_trans
    {κ α : Type}
    [DecidableEq κ]
    (s : State κ α)
    (stack : List (Nat × Binding κ α))
    (target₁ target₂ : Nat)
    (h : target₂ ≤ target₁)
    : let r₁ := processEvents.undoTo s stack target₁
      let r₂ := processEvents.undoTo r₁.1 r₁.2 target₂
      processEvents.undoTo s stack target₂ = r₂ := by
  induction stack generalizing s with
  | nil => simp [processEvents.undoTo]
  | cons p rest ih =>
    cases p with
    | mk slot inv =>
      by_cases h₂ : slot > target₂
      · by_cases h₁ : slot > target₁
        · -- Both pop this entry
          simp only [processEvents.undoTo, h₁, h₂, ↓reduceIte]
          exact ih (swap s inv).1
        · -- target₂ < slot ≤ target₁
          -- undoTo at target₁ stops, undoTo at target₂ pops
          simp only [processEvents.undoTo, h₁, h₂, ↓reduceIte]
      · -- slot ≤ target₂: both stop
        have h₁ : ¬(slot > target₁) := by omega
        simp only [processEvents.undoTo, h₁, h₂, ↓reduceIte]

/-- interleaveRollbacks for two-or-more children decomposes
    into the first child's walk, a rollBack, and the rest. -/
theorem interleaveRollbacks_cons₂
    {κ α : Type}
    (slot : Nat)
    (w₁ : List (ChainEvent κ α))
    (w₂ : List (ChainEvent κ α))
    (ws : List (List (ChainEvent κ α)))
    : dfsSubtree.interleaveRollbacks slot (w₁ :: w₂ :: ws)
    = w₁ ++ [ChainEvent.rollBack slot]
        ++ dfsSubtree.interleaveRollbacks slot (w₂ :: ws) := by
  simp [dfsSubtree.interleaveRollbacks]

/-- Helper for the multi-child case of goFull_dfsSubtree.
    Processes interleaveRollbacks of children walks, showing
    that each non-last child's DFS + rollBack is a no-op. -/
theorem goFull_interleaveRollbacks
    {κ α : Type}
    [DecidableEq κ]
    (children : List (BlockTree κ α))
    (s : State κ α)
    (stack : List (Nat × Binding κ α))
    (parentSlot : Nat)
    (hChildren : ∀ c ∈ children, allSlotsGt parentSlot c)
    (hOrdChildren : ∀ c ∈ children, slotsOrdered c)
    (hStack : ∀ p ∈ stack, p.1 ≤ parentSlot)
    (hNe : children ≠ [])
    -- For recursive calls in goFull_dfsSubtree,
    -- we need that each child is smaller than some bound.
    -- We parameterize by the inductive hypothesis.
    (ih : ∀ c ∈ children,
      ∀ (s' : State κ α)
        (stack' : List (Nat × Binding κ α))
        (bound' : Nat),
        allSlotsGt bound' c →
        slotsOrdered c →
        (∀ p ∈ stack', p.1 ≤ bound') →
        (goFull s' stack' (dfsSubtree c)).1
          = applyBlocks s' (canonical c)
        ∧ (∃ newEntries,
            (goFull s' stack' (dfsSubtree c)).2
            = newEntries ++ stack'
            ∧ stackSlotsGt bound' newEntries)
        ∧ processEvents.undoTo
            (goFull s' stack' (dfsSubtree c)).1
            (goFull s' stack' (dfsSubtree c)).2
            bound'
          = (s', stack'))
    : -- (1) State: equals applying the last child's canonical
      (goFull s stack
        (dfsSubtree.interleaveRollbacks parentSlot
          (children.map dfsSubtree))).1
      = applyBlocks s
          (canonical (List.last' (children.head hNe)
            (children.tail)))
    -- (2) Stack
    ∧ (∃ newEntries,
        (goFull s stack
          (dfsSubtree.interleaveRollbacks parentSlot
            (children.map dfsSubtree))).2
        = newEntries ++ stack
        ∧ stackSlotsGt parentSlot newEntries)
    -- (3) Rollback
    ∧ processEvents.undoTo
        (goFull s stack
          (dfsSubtree.interleaveRollbacks parentSlot
            (children.map dfsSubtree))).1
        (goFull s stack
          (dfsSubtree.interleaveRollbacks parentSlot
            (children.map dfsSubtree))).2
        parentSlot
      = (s, stack) := by
  match children, hNe with
  | [c], _ =>
    -- Single child: interleaveRollbacks _ [w] = w
    simp only [List.map, dfsSubtree.interleaveRollbacks,
      List.head_cons, List.tail_cons, List.last']
    -- Apply IH to c
    have hc := ih c (by simp) s stack parentSlot
      (hChildren c (by simp)) (hOrdChildren c (by simp)) hStack
    exact hc
  | c₁ :: c₂ :: cs, _ =>
    -- interleaveRollbacks decomposes
    simp only [List.map]
    rw [interleaveRollbacks_cons₂]
    -- Split goFull over the append
    rw [goFull_append]
    -- After dfsSubtree c₁: get intermediate result
    -- Then process [rollBack parentSlot] ++ rest
    -- Use goFull_append again for the rollBack
    rw [goFull_append]
    -- After [rollBack parentSlot]: this is goFull on the
    -- result of dfsSubtree c₁
    -- By IH on c₁, undoTo at parentSlot restores (s, stack)
    have ih_c₁ := ih c₁ (by simp) s stack parentSlot
      (hChildren c₁ (by simp)) (hOrdChildren c₁ (by simp)) hStack
    obtain ⟨_, ⟨newE₁, hNewE₁, hNewGt₁⟩, hUndo₁⟩ := ih_c₁
    -- After dfsSubtree c₁, the state and stack are known.
    -- goFull on [rollBack parentSlot]:
    simp only [goFull]
    -- undoTo at parentSlot on the result = (s, stack)
    rw [hUndo₁]
    -- Now we process the remaining interleaveRollbacks
    -- from state s and stack, same as the original problem
    -- but with children = c₂ :: cs
    have hNe' : (c₂ :: cs) ≠ [] := by simp
    have hChildren' : ∀ c ∈ (c₂ :: cs),
        allSlotsGt parentSlot c := by
      intro c hc; exact hChildren c (by simp [hc])
    have hOrd' : ∀ c ∈ (c₂ :: cs), slotsOrdered c := by
      intro c hc; exact hOrdChildren c (by simp [hc])
    have ih' : ∀ c ∈ (c₂ :: cs),
        ∀ (s' : State κ α)
          (stack' : List (Nat × Binding κ α))
          (bound' : Nat),
          allSlotsGt bound' c →
          slotsOrdered c →
          (∀ p ∈ stack', p.1 ≤ bound') →
          (goFull s' stack' (dfsSubtree c)).1
            = applyBlocks s' (canonical c)
          ∧ (∃ newEntries,
              (goFull s' stack' (dfsSubtree c)).2
              = newEntries ++ stack'
              ∧ stackSlotsGt bound' newEntries)
          ∧ processEvents.undoTo
              (goFull s' stack' (dfsSubtree c)).1
              (goFull s' stack' (dfsSubtree c)).2
              bound'
            = (s', stack') := by
      intro c hc; exact ih c (by simp [hc])
    have recResult := goFull_interleaveRollbacks
      (c₂ :: cs) s stack parentSlot
      hChildren' hOrd' hStack hNe' ih'
    -- The result for c₂ :: cs is what we need, but with
    -- List.last' adjusted.
    -- List.last' (c₁::c₂::cs).head (c₁::c₂::cs).tail
    -- = List.last' c₁ (c₂ :: cs)
    -- = List.last' c₂ cs
    -- List.last' (c₂::cs).head (c₂::cs).tail
    -- = List.last' c₂ cs
    -- So they match!
    -- The goal now has (s, stack).fst and (s, stack).snd
    -- which we need to simplify
    simp only []
    -- Now the goal is about goFull s stack on
    -- interleaveRollbacks parentSlot (dfsSubtree c₂ :: map dfsSubtree cs)
    -- which equals recResult but with adjusted List.last'
    have hGoal :
        (goFull s stack
          (dfsSubtree.interleaveRollbacks parentSlot
            (dfsSubtree c₂ :: List.map dfsSubtree cs))).1
        = applyBlocks s
            (canonical (List.last' c₁ (c₂ :: cs)))
      ∧ (∃ newEntries,
          (goFull s stack
            (dfsSubtree.interleaveRollbacks parentSlot
              (dfsSubtree c₂ :: List.map dfsSubtree cs))).2
          = newEntries ++ stack
          ∧ stackSlotsGt parentSlot newEntries)
      ∧ processEvents.undoTo
          (goFull s stack
            (dfsSubtree.interleaveRollbacks parentSlot
              (dfsSubtree c₂ :: List.map dfsSubtree cs))).1
          (goFull s stack
            (dfsSubtree.interleaveRollbacks parentSlot
              (dfsSubtree c₂ :: List.map dfsSubtree cs))).2
          parentSlot
        = (s, stack) := by
      -- recResult says the same thing but with
      -- List.last' (c₂::cs).head (c₂::cs).tail
      -- = List.last' c₂ cs
      -- and we need List.last' c₁ (c₂::cs) = List.last' c₂ cs
      have hlast₁ : List.last' c₁ (c₂ :: cs)
          = List.last' c₂ cs := by
        simp [List.last']
      have hlast₂ : List.last' ((c₂ :: cs).head hNe')
          (c₂ :: cs).tail = List.last' c₂ cs := by
        simp [List.head_cons, List.tail_cons]
      -- Also need: map dfsSubtree (c₂ :: cs)
      -- = dfsSubtree c₂ :: map dfsSubtree cs
      have hmap : List.map dfsSubtree (c₂ :: cs)
          = dfsSubtree c₂ :: List.map dfsSubtree cs := by
        simp
      rw [hlast₁]
      rw [← hlast₂, ← hmap]
      exact recResult
    -- Now adjust for the (c₁::c₂::cs) head/tail
    simp only [List.head_cons, List.tail_cons]
    exact hGoal

/-- Core inductive lemma: processing `dfsSubtree t` from
    `(s, stack)` yields state `applyBlocks s (canonical t)`
    and a stack whose new entries all have slots from blocks
    in the tree (all > some bound if `allSlotsGt bound t`).

    We prove: (1) the state is correct, and
    (2) the stack has the form `newEntries ++ stack`
    where all new entries have slot > bound.

    For the induction to work, we need slot ordering. -/
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
    : -- (1) State equals canonical chain application
      (goFull s stack (dfsSubtree t)).1
      = applyBlocks s (canonical t)
      -- (2) Stack has new entries prepended, all > bound
    ∧ (∃ newEntries : List (Nat × Binding κ α),
        (goFull s stack (dfsSubtree t)).2
        = newEntries ++ stack
        ∧ stackSlotsGt bound newEntries)
      -- (3) undoTo at bound restores state and stack
    ∧ processEvents.undoTo
        (goFull s stack (dfsSubtree t)).1
        (goFull s stack (dfsSubtree t)).2
        bound
      = (s, stack) := by
  match t with
  | .leaf b =>
    simp only [dfsSubtree, goFull, canonical, applyBlocks,
      applyBlock]
    have hgt : b.slot > bound := by
      simp [allSlotsGt] at hSlots; exact hSlots
    exact ⟨ trivial
      , ⟨[(b.slot, (swap s b.binding).2)],
          by simp,
          by intro p hp
             simp only [List.mem_cons, List.not_mem_nil,
               or_false] at hp
             subst hp; exact hgt⟩
      , by rw [undoTo_pop _ _ _ _ _ hgt,
               undoTo_all_below _ _ _ hStack]
           have := single_step_rollback s b.binding
           simp only [this]
      ⟩
  | .fork b children =>
    simp only [dfsSubtree, goFull]
    have hb_gt : b.slot > bound := by
      simp [allSlotsGt] at hSlots; exact hSlots.1
    have hStack' : ∀ p ∈ (b.slot, (swap s b.binding).2)
        :: stack, p.1 ≤ b.slot := by
      intro p hp
      simp only [List.mem_cons] at hp
      cases hp with
      | inl h => subst h; simp
      | inr h => have := hStack p h; omega
    match children with
    | [] =>
      simp only [List.map, dfsSubtree.interleaveRollbacks,
        goFull, canonical, applyBlocks, applyBlock]
      exact ⟨ trivial
        , ⟨[(b.slot, (swap s b.binding).2)],
            by simp,
            by intro p hp
               simp only [List.mem_cons, List.not_mem_nil,
                 or_false] at hp
               subst hp; exact hb_gt⟩
        , by rw [undoTo_pop _ _ _ _ _ hb_gt,
                 undoTo_all_below _ _ _ hStack]
             have := single_step_rollback s b.binding
             simp only [this]
        ⟩
    | [c] =>
      simp only [List.map, dfsSubtree.interleaveRollbacks]
      have hc_slots : allSlotsGt b.slot c := by
        simp only [allSlotsGt] at hSlots
        exact hSlots.2 c (by simp)
      have hc_ord : slotsOrdered c := by
        simp only [slotsOrdered] at hOrd
        exact hOrd.2 c (by simp)
      have ih_c := goFull_dfsSubtree c
        (swap s b.binding).1
        ((b.slot, (swap s b.binding).2) :: stack)
        b.slot hc_slots hc_ord hStack'
      have hlast : List.last' c [] = c := by
        simp [List.last']
      obtain ⟨ih_state, ⟨newE, hNewE, hNewGt⟩, ih_rb⟩ := ih_c
      refine ⟨?_, ?_, ?_⟩
      · -- (1) State
        rw [ih_state]
        simp only [canonical, applyBlocks, applyBlock, hlast]
      · -- (2) Stack
        exact ⟨newE ++ [(b.slot, (swap s b.binding).2)],
          by rw [hNewE]; simp [List.append_assoc],
          by intro p hp
             simp only [List.mem_append, List.mem_cons,
               List.not_mem_nil, or_false] at hp
             cases hp with
             | inl h => have := hNewGt p h; omega
             | inr h => subst h; exact hb_gt⟩
      · -- (3) undoTo at bound on the result
        -- Stack is newE ++ (b.slot, inv) :: stack
        -- All newE have slot > b.slot > bound
        -- (b.slot, inv) has slot = b.slot > bound
        -- So all of (newE ++ [(b.slot, inv)]) > bound
        -- undoTo pops all of them, restoring state to s.
        rw [ih_state, hNewE]
        -- Now: undoTo (applyBlocks ...) (newE ++ (b.slot, inv) :: stack) bound = (s, stack)
        rw [show newE ++ (b.slot, (swap s b.binding).2) :: stack
          = (newE ++ [(b.slot, (swap s b.binding).2)]) ++ stack
          from by simp [List.append_assoc]]
        have hAllGt : stackSlotsGt bound
            (newE ++ [(b.slot, (swap s b.binding).2)]) := by
          intro p hp
          simp only [List.mem_append, List.mem_cons,
            List.not_mem_nil, or_false] at hp
          cases hp with
          | inl h => have := hNewGt p h; omega
          | inr h => subst h; exact hb_gt
        -- Use undoTo_trans: split into undoTo at b.slot,
        -- then undoTo at bound
        rw [show (newE ++ [(b.slot, (swap s b.binding).2)])
            ++ stack
          = newE ++ (b.slot, (swap s b.binding).2) :: stack
          from by simp [List.append_assoc]]
        rw [← hNewE]
        rw [← ih_state]
        rw [undoTo_trans _ _ b.slot bound (by omega)]
        rw [ih_rb]
        -- Now: undoTo (swap s b.binding).1
        --   ((b.slot, inv) :: stack) bound
        rw [undoTo_pop _ _ _ _ _ hb_gt]
        rw [undoTo_all_below _ _ _ hStack]
        have := single_step_rollback s b.binding
        simp only [this]
    | c₁ :: c₂ :: cs =>
      -- Use goFull_interleaveRollbacks with the IH from
      -- recursive calls to goFull_dfsSubtree on children
      have hChildSlots : ∀ c ∈ (c₁ :: c₂ :: cs),
          allSlotsGt b.slot c := by
        simp only [allSlotsGt] at hSlots
        exact hSlots.2
      have hChildOrd : ∀ c ∈ (c₁ :: c₂ :: cs),
          slotsOrdered c := by
        simp only [slotsOrdered] at hOrd
        exact hOrd.2
      have ih_children : ∀ c ∈ (c₁ :: c₂ :: cs),
          ∀ (s' : State κ α)
            (stack' : List (Nat × Binding κ α))
            (bound' : Nat),
            allSlotsGt bound' c →
            slotsOrdered c →
            (∀ p ∈ stack', p.1 ≤ bound') →
            (goFull s' stack' (dfsSubtree c)).1
              = applyBlocks s' (canonical c)
            ∧ (∃ newEntries,
                (goFull s' stack' (dfsSubtree c)).2
                = newEntries ++ stack'
                ∧ stackSlotsGt bound' newEntries)
            ∧ processEvents.undoTo
                (goFull s' stack' (dfsSubtree c)).1
                (goFull s' stack' (dfsSubtree c)).2
                bound'
              = (s', stack') := by
        intro c hc s' stack' bound' hS hO hSt
        exact goFull_dfsSubtree c s' stack' bound' hS hO hSt
      have result := goFull_interleaveRollbacks
        (c₁ :: c₂ :: cs)
        (swap s b.binding).1
        ((b.slot, (swap s b.binding).2) :: stack)
        b.slot hChildSlots hChildOrd hStack'
        (by simp) ih_children
      obtain ⟨rState, ⟨newE, hNewE, hNewGt⟩, rUndo⟩ := result
      refine ⟨?_, ?_, ?_⟩
      · -- (1) State
        rw [rState]
        simp only [canonical, applyBlocks, applyBlock,
          List.head_cons, List.tail_cons]
      · -- (2) Stack
        exact ⟨newE ++ [(b.slot, (swap s b.binding).2)],
          by rw [hNewE]; simp [List.append_assoc],
          by intro p hp
             simp only [List.mem_append, List.mem_cons,
               List.not_mem_nil, or_false] at hp
             cases hp with
             | inl h => have := hNewGt p h; omega
             | inr h => subst h; exact hb_gt⟩
      · -- (3) Rollback
        rw [rState, hNewE]
        rw [show newE ++ (b.slot, (swap s b.binding).2)
              :: stack
          = (newE ++ [(b.slot, (swap s b.binding).2)])
              ++ stack
          from by simp [List.append_assoc]]
        -- rewrite back for undoTo_trans
        rw [show (newE ++ [(b.slot, (swap s b.binding).2)])
              ++ stack
          = newE ++ (b.slot, (swap s b.binding).2) :: stack
          from by simp [List.append_assoc]]
        rw [← hNewE, ← rState]
        rw [undoTo_trans _ _ b.slot bound (by omega)]
        rw [rUndo]
        rw [undoTo_pop _ _ _ _ _ hb_gt]
        rw [undoTo_all_below _ _ _ hStack]
        have := single_step_rollback s b.binding
        simp only [this]
termination_by sizeOf t

-- ============================================================
-- Main theorem
-- ============================================================

/-- For any well-formed block tree, processing the DFS
    walk produces the same state as applying the
    canonical chain directly.

    This is the fundamental correctness property:
    the journey through forks doesn't matter, only
    the final canonical path determines the state. -/
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
    = applyBlocks s (canonical t) := by
  unfold dfs processEvents
  rw [go_eq_goFull_fst]
  exact (goFull_dfsSubtree t s [] 0 hSlots hOrd
    (by intro p hp; simp at hp)).1
