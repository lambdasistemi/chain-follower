# Feature Specification: processBlock Tracer

**Feature Branch**: `004-processblock-tracer`
**Created**: 2026-04-01
**Status**: Draft
**Input**: GitHub issue #23 — add tracer to processBlock for phase transition events

## User Scenarios & Testing

### User Story 1 - Phase transition is visible in logs (Priority: P1)

When the Runner transitions from `InRestoration` to `InFollowing`, a trace event is emitted. This is the critical event that was missing in production.

**Why this priority**: The preprod bug went undetected because this transition was invisible.

**Independent Test**: Process blocks with `atTip=False` then `atTip=True`, verify the tracer receives a transition event.

**Acceptance Scenarios**:

1. **Given** a Runner in `InRestoration`, **When** `processBlock` is called with `atTip=True`, **Then** a `PhaseTransition` event is emitted.
2. **Given** a Runner in `InFollowing`, **When** `processBlock` is called, **Then** no transition event is emitted.

---

### User Story 2 - Every block processing is traceable (Priority: P2)

Each `processBlock` call emits an event indicating which phase handled the block and the slot.

**Why this priority**: Allows operators to see the block-by-block progression and spot when restoration runs too long.

**Acceptance Scenarios**:

1. **Given** a Runner in `InRestoration`, **When** a block at slot S is processed, **Then** a `BlockRestored S` event is emitted.
2. **Given** a Runner in `InFollowing`, **When** a block at slot S is processed, **Then** a `BlockFollowed S` event is emitted.

---

### Edge Cases

- `atTip=True` on the very first block (immediate transition) — still emits transition event
- `atTip=True` when already `InFollowing` — no transition event, just `BlockFollowed`

## Requirements

### Functional Requirements

- **FR-001**: `processBlock` MUST accept a `Tracer` parameter for `RunnerEvent`
- **FR-002**: A `PhaseTransition` event MUST be emitted on `InRestoration` → `InFollowing`
- **FR-003**: A `BlockRestored slot` event MUST be emitted for each block in restoration
- **FR-004**: A `BlockFollowed slot` event MUST be emitted for each block in following
- **FR-005**: Existing callers MUST be updated (Laws.hs, tests, tutorial)

### Key Entities

- **RunnerEvent slot**: Sum type of trace events emitted by the Runner
- **Tracer**: From `contra-tracer`, the standard tracing abstraction

## Success Criteria

- **SC-001**: All existing tests pass with the new tracer parameter
- **SC-002**: New test verifies transition event is emitted
- **SC-003**: `just ci` green
- **SC-004**: No performance impact when tracer is `nullTracer`

## Assumptions

- `contra-tracer` is already a transitive dependency (used by cardano-node-clients)
- Adding a `Tracer` parameter is a breaking API change — all callers must update
