# Chain Follower Constitution

## Core Principles

### I. CPS Backend Interface
The backend provides two phase continuations (Restoring and Following) as records. The Runner owns phase transitions. The backend always offers both options via `toFollowing` and `toRestoring`.

### II. Lean-Verified Invariants
Rollback correctness, pruning properties, and state machine transitions are formalized in Lean 4. No `sorry` in proofs. Tests map to Lean theorems.

### III. QuickCheck State Machine Testing
All Runner properties are tested via randomized chain event sequences (forwards + rollbacks + forks). Final state must match clean canonical replay.

### IV. Transaction Atomicity
Block processing and rollback storage happen in the same transaction. The Runner and backend share the transaction monad `t`.

### V. Performance by Design
Restoration mode exists for bulk ingestion without inverse computation or rollback storage. The Runner must use restoration when far from tip and only switch to following when near tip.

## Quality Gates

- All Lean proofs compile with no `sorry`
- `just ci` passes (build, test, format, hlint, cabal-check)
- QuickCheck properties cover all state transitions including restoration→following

## Development Workflow

- Nix-first: all tools from `nix develop`
- Fourmolu formatting, hlint clean
- Linear git history via rebase merge
- Every feature goes through speckit: specify → plan → tasks → implement

**Version**: 1.0.0 | **Ratified**: 2026-03-30
