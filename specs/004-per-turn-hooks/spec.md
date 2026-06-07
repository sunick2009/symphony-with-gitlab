# Feature Specification: Per-Turn Workspace Hooks

**Feature Branch**: `004-per-turn-hooks`

**Created**: 2026-06-07

**Status**: Implemented

**Input**: Run workspace hooks between Codex turns so the multi-phase plan syncs to the tracker (GitLab) before execution begins, and progress syncs after every phase instead of only at the end of the agent run.

## Background

Symphony's multi-phase workflow (`elixir/WORKFLOW.gitlab.md`) drives Codex to first write a plan (`output/workpad.md`) in a planning turn, then execute one phase per subsequent turn. Progress is mirrored to the GitLab issue via the `after_run` hook.

The current architecture calls `before_run` and `after_run` exactly once per agent run — both live in `AgentRunner.run_on_worker_host/4`, wrapping the entire `run_codex_turns` recursion. As a result the GitLab workpad comment is only created/updated **after all turns complete**. The plan written in turn 1 does not appear in GitLab until the final turn finishes, defeating the "plan first, then execute" intent and giving operators no mid-run visibility.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Plan Appears Before Execution (Priority: P1)

An operator dispatches a multi-phase task. Codex writes its plan in the planning turn. The operator wants to see that plan in the GitLab issue **before** Codex starts executing phases, so they can intervene early if the plan is wrong.

**Why this priority**: This is the core intent of "計劃先出現再執行". Without per-turn hook execution the plan only surfaces at the very end, which is the exact limitation this feature removes.

**Independent Test**: Configure an `after_turn` hook and run an agent with `max_turns >= 2` where the issue stays active after turn 1. Verify the hook is invoked after turn 1 completes and before turn 2's prompt is built.

**Acceptance Scenarios**:

1. **Given** an `after_turn` hook is configured, **When** turn 1 completes and the issue is still active, **Then** the `after_turn` hook runs before turn 2 begins.
2. **Given** a `before_turn` hook is configured, **When** each turn is about to start, **Then** the `before_turn` hook runs before that turn's prompt is sent to Codex — including turn 1.
3. **Given** neither `before_turn` nor `after_turn` is configured, **When** an agent run executes, **Then** behavior is identical to today (no extra hook invocations, same logs).

---

### User Story 2 - Progress Syncs After Each Phase (Priority: P1)

An operator watches a long multi-phase run. After each phase completes they want the GitLab workpad comment updated with the latest checklist state and a timestamp, rather than waiting for the whole run.

**Why this priority**: Mid-run progress visibility is the second half of the value. It turns the workpad into a live progress tracker.

**Independent Test**: Run an agent across 3 turns and assert the `after_turn` hook is called once per completed turn (3 times), each time after the turn completes.

**Acceptance Scenarios**:

1. **Given** an agent runs N turns, **When** each turn completes, **Then** the `after_turn` hook is invoked exactly once per completed turn.
2. **Given** the `after_turn` hook is invoked, **When** it runs, **Then** the workspace state (workpad, evidence) written by that turn is visible to the hook command.

---

### User Story 3 - Hook Failures Do Not Abort the Run (Priority: P2)

A transient GitLab outage causes an `after_turn` sync to fail mid-run. The operator expects the agent to keep working and retry sync on the next turn, not crash the whole run over a temporary network error.

**Why this priority**: Per-turn hooks touch the network every turn, multiplying transient-failure exposure. Sync is observability, not correctness, so it must be non-fatal — matching the existing `after_run` behavior.

**Independent Test**: Configure an `after_turn` hook that exits non-zero and verify the agent run still proceeds to the next turn and completes.

**Acceptance Scenarios**:

1. **Given** an `after_turn` hook that exits non-zero, **When** a turn completes, **Then** the failure is logged as a warning and the run continues to the next turn.
2. **Given** a `before_turn` hook that exits non-zero, **When** a turn is about to start, **Then** the failure is logged as a warning and the turn still proceeds.

---

### Edge Cases

- **Single-turn run**: If the issue becomes terminal after turn 1, `after_turn` still runs once (after turn 1); `before_turn` runs once (before turn 1). `before_run`/`after_run` still wrap the whole run exactly once.
- **max_turns reached**: `after_turn` runs after the final allowed turn even though no further turn follows.
- **Hook ordering**: For a run of N turns the sequence is `before_run` → (`before_turn` → turn → `after_turn`) × N → `after_run`.
- **Remote SSH worker**: Per-turn hooks honor the same `worker_host` execution path as existing hooks.
- **Empty-string hook command**: Treated as absent (no invocation), consistent with other hooks.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST support an optional `hooks.before_turn` command that runs before every Codex turn, including the first turn.
- **FR-002**: The system MUST support an optional `hooks.after_turn` command that runs after every Codex turn completes, before the continuation decision advances to the next turn.
- **FR-003**: For an N-turn agent run, `before_turn` MUST be invoked exactly N times and `after_turn` MUST be invoked exactly N times.
- **FR-004**: `before_run` MUST continue to run exactly once before the first turn, and `after_run` exactly once after the last turn, preserving the overall order `before_run → (before_turn → turn → after_turn) × N → after_run`.
- **FR-005**: Both `before_turn` and `after_turn` failures (non-zero exit or timeout) MUST be logged but MUST NOT abort the agent run.
- **FR-006**: Per-turn hooks MUST execute in the issue workspace and support remote `worker_host` execution identically to existing hooks.
- **FR-007**: When `before_turn`/`after_turn` are unset (nil or empty string), the system MUST behave exactly as before this feature (no behavior or log changes).
- **FR-008**: Per-turn hooks MUST be tracker-agnostic (available to both Linear and GitLab), since they operate on the workspace.

### Key Entities

- **Hooks config** (`SymphonyElixir.Config.Schema.Hooks`): gains `before_turn` and `after_turn` string fields alongside the existing `after_create`, `before_run`, `after_run`, `before_remove`, `timeout_ms`.
- **AgentRunner turn loop** (`do_run_codex_turns/8`): the recursion where per-turn hooks are invoked around `AppServer.run_turn`.
- **Workspace hook runner** (`Workspace.run_before_turn_hook/3`, `run_after_turn_hook/3`): new public functions mirroring `run_before_run_hook`/`run_after_run_hook`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With an `after_turn` hook configured, the hook is invoked after turn 1 (planning) and after each subsequent phase turn — verifiable by hook invocation count equal to turn count.
- **SC-002**: Existing workflows with no `before_turn`/`after_turn` configured produce identical hook-invocation behavior to before the change (regression-safe).
- **SC-003**: A failing per-turn hook never aborts an agent run; the run completes the same number of turns it would have without the failure.
- **SC-004**: The full hook ordering `before_run → (before_turn → turn → after_turn) × N → after_run` holds for a multi-turn run, asserted by an ordered invocation test.
- **SC-005**: `mix test` passes with new unit tests covering FR-001 through FR-007.

## Assumptions

- The planning workflow already ends the turn after writing the plan (turn 1 = planning, turn 2+ = execution); this feature only changes *when hooks fire*, not the turn loop's continuation logic.
- GitLab sync logic lives in the hook command (shell), not in Elixir; the Elixir change is limited to invoking hooks at the right points. Existing `WORKFLOW.gitlab.md` migrates `before_run`→`before_turn` and `after_run`→`after_turn` to gain per-phase behavior.
- Non-fatal semantics for per-turn hooks match the existing `after_run` precedent (`ignore_hook_failure`).
- The Codex app-server session persists across turns (existing behavior); per-turn hooks run on the shared workspace between `AppServer.run_turn` calls without restarting the session.
