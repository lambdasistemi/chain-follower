# Feature Specification: Restoration→Following Phase Transition

**Feature Branch**: `feat/phase-transition`
**Created**: 2026-03-30
**Status**: Draft
**Input**: lambdasistemi/chain-follower#18

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Automatic phase transition during initial sync (Priority: P1)

A chain-follower consumer starts syncing from genesis. The Runner begins in `InRestoration` mode (fast bulk ingestion, no inverse computation, no rollback storage). When the current block slot approaches the chain tip, the Runner automatically transitions to `InFollowing` mode (with rollback support).

**Why this priority**: This is the core feature. Without it, initial sync is ~60x slower than necessary because every block goes through the expensive following path.

**Independent Test**: Process a sequence of blocks through `processBlock` starting in `InRestoration`. When a block's slot matches the tip signal, the returned phase should be `InFollowing`. The final state must match a clean following-only run.

**Acceptance Scenarios**:

1. **Given** the Runner starts in `InRestoration`, **When** blocks are processed with slots far from tip, **Then** the phase remains `InRestoration` and no rollback points are stored.
2. **Given** the Runner is in `InRestoration`, **When** a block's slot reaches the tip, **Then** the Runner transitions to `InFollowing` (calling `toFollowing` on the backend) and subsequent blocks produce rollback points.
3. **Given** a full sync from genesis with a transition at slot N, **When** compared to a clean canonical replay, **Then** the final state is identical.

---

### User Story 2 - Rollback during following after transition (Priority: P2)

After transitioning from restoration to following, rollbacks must work correctly. Only blocks processed in following mode have rollback points; rollback cannot go back into the restoration region.

**Why this priority**: Rollback correctness is essential for chain-following consumers.

**Independent Test**: Process blocks in restoration, transition to following, process more blocks, then roll back within the following region. Verify state matches the snapshot at that point.

**Acceptance Scenarios**:

1. **Given** the Runner transitioned to `InFollowing` at slot N and processed blocks N..N+K, **When** rolling back to slot N+1, **Then** the state matches the snapshot at N+1.
2. **Given** the Runner transitioned at slot N, **When** attempting rollback to a slot before N, **Then** the rollback returns `RollbackImpossible`.

---

### Edge Cases

- What happens if the tip signal says "at tip" from the very first block? The Runner should immediately transition to following.
- What happens if the tip recedes (chain tip goes backward during sync)? The Runner should stay in restoration until the signal says "at tip" again.
- What happens on restart with existing rollback points? `resumeFollowing` should be used (existing behavior for restart).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `processBlock` MUST accept a tip proximity signal (e.g. a boolean `atTip` or a comparison of current slot vs tip slot)
- **FR-002**: When in `InRestoration` and the tip signal indicates "at tip", the Runner MUST call `toFollowing` on the backend and switch to `InFollowing`
- **FR-003**: When in `InRestoration` and the tip signal indicates "not at tip", the Runner MUST stay in `InRestoration` with no rollback storage
- **FR-004**: When in `InFollowing`, the Runner MUST continue following regardless of the tip signal (no reverse transition during normal operation)
- **FR-005**: The `toFollowing` transition runs in the outer monad `m` (not in the transaction), because it may involve journal replay
- **FR-006**: After transition, the first following block MUST produce rollback data normally

### Key Entities

- **Phase**: Sum type with `InRestoration` and `InFollowing` constructors — unchanged
- **TipSignal**: A way for the caller to indicate proximity to tip — could be a `Bool`, a slot comparison, or a callback

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Initial sync from genesis uses `InRestoration` for all blocks until tip proximity, achieving 1000+ blk/s
- **SC-002**: All existing QuickCheck properties continue to pass
- **SC-003**: New property: restoration+transition final state equals clean following-only final state
- **SC-004**: New property: rollback after transition works within the following region

## Assumptions

- The caller (application) knows the chain tip slot and can provide a tip proximity signal per block
- `toFollowing` on the backend handles journal replay internally (as it does today)
- The `InFollowing` → `InRestoration` reverse transition is not needed for this feature (armageddon handles that case)
- Existing tests that start in `InFollowing` remain valid for testing rollback behavior
