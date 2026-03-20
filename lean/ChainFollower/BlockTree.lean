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
-- Main theorem (with sorry — to be proved)
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
    (wf : wellFormed k t)
    (s : State κ α)
    : processEvents s (dfs t)
    = applyBlocks s (canonical t) := by
  sorry
