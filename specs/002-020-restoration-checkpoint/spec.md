# Feature Specification: Restoration Checkpoint in Runner

**Feature Branch**: `feat/restoration-checkpoint`
**Created**: 2026-03-31
**Status**: Draft
**Input**: lambdasistemi/chain-follower#20

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Atomic checkpoint during restoration (Priority: P1)

During restoration, every block's checkpoint is stored atomically with the block processing. On restart, the Runner resumes from the last checkpointed block instead of from origin.

**Why this priority**: Without this, restarts after crash reprocess all blocks from origin or from a stale checkpoint, corrupting the journal.

**Independent Test**: Process N blocks in restoration, kill, restart, verify resume point is at block N.

**Acceptance Scenarios**:

1. **Given** the Runner processes blocks 1..100 in restoration, **When** it restarts, **Then** it resumes from block 100 (not origin).
2. **Given** the Runner crashes at block 50, **When** it restarts, **Then** it resumes from block 50 (the last committed transaction included the checkpoint).
3. **Given** the Runner transitions to following at block 100, **When** it processes blocks 101..110 in following, **Then** rollback points exist for 101..110 and the checkpoint is at 100.

---

### User Story 2 - Checkpoint replaces onBlock for consumers (Priority: P2)

The consumer no longer needs to provide a checkpoint action via `onBlock`. The Runner manages the checkpoint internally using a checkpoint column, symmetric with how it manages the rollback column in following mode.

**Why this priority**: Simplifies consumer code and eliminates a class of bugs where consumers forget to checkpoint or checkpoint inconsistently.

**Independent Test**: The consumer calls `start` and `processBlock` with no checkpoint logic. On restart, resume works correctly.

**Acceptance Scenarios**:

1. **Given** the Runner is configured with a checkpoint column, **When** `processBlock` runs in restoration, **Then** the checkpoint is written atomically inside the transaction without consumer involvement.
2. **Given** the consumer provides no `onBlock` checkpoint logic, **When** the Runner restarts, **Then** it reads the checkpoint from the column and resumes correctly.

---

### Edge Cases

- What happens if the checkpoint column is empty on first start? The Runner starts from origin.
- What happens on transition from restoration to following? The checkpoint becomes the base for the first rollback point.
- What happens on restart in following mode? The rollback points define the resume range — the checkpoint is not needed.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The Runner MUST store a checkpoint (block slot/point) atomically with each `restore` call during restoration
- **FR-002**: The Runner MUST read the checkpoint on `start` to determine the resume point
- **FR-003**: The checkpoint column MUST be owned by the Runner (passed as a parameter like `RollbackCol`)
- **FR-004**: On transition to following, the checkpoint MUST be preserved as the base point
- **FR-005**: The `onBlock` callback MUST remain available for non-checkpoint consumer logic but MUST NOT be required for checkpoint management
- **FR-006**: `start` MUST return the checkpoint (if any) so the consumer can use it as the intersection point

### Key Entities

- **CheckpointCol**: A column selector for the checkpoint, storing a single slot/point value
- **Phase**: `InRestoration` now implicitly manages the checkpoint
- **Init.start**: Returns `(Maybe slot, Restoring ...)` — the checkpoint and the restoring continuation

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Consumer code for checkpoint management is eliminated (no `putBaseCheckpoint` in downstream)
- **SC-002**: Restart after crash resumes within 1 block of where it stopped
- **SC-003**: All existing tests pass with the new checkpoint mechanism
- **SC-004**: New test: crash simulation verifies checkpoint atomicity

## Assumptions

- The checkpoint is a single value (last processed slot), not a history
- The slot type is `Ord` (same constraint as rollback points)
- The consumer provides the checkpoint column selector at initialization (like `RollbackCol`)
- Following mode does not update the checkpoint — rollback points handle resume
