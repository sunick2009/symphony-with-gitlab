# Tasks: GitLab Control Plane Stabilization

**Input**: Design documents from `specs/001-gitlab-control-plane/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: Required. This phase is stabilization and must prove lifecycle behavior before it is considered complete.

**Organization**: Tasks are grouped by independently testable user stories.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel because it touches different files or independent tests.
- **[Story]**: User story label from `spec.md`.
- Every task includes an exact file path.

## Phase 1: Setup and Existing Failure Investigation

**Purpose**: Establish validation baseline and identify the current full-suite blocker before changing lifecycle behavior.

- [x] T001 Record current targeted validation commands and results in `specs/001-gitlab-control-plane/plan.md`
- [x] T002 Investigate `elixir/test/symphony_elixir/core_test.exs:1003` workspace hook failure and document root cause in `specs/001-gitlab-control-plane/research.md`
- [x] T003 Fix or isolate the workspace hook shell compatibility issue in `elixir/lib/symphony_elixir/workspace.ex` or `elixir/test/symphony_elixir/core_test.exs`
- [x] T004 Re-run the affected agent-runner tests in `elixir/test/symphony_elixir/core_test.exs`

---

## Phase 2: Foundational GitLab Safety Tests

**Purpose**: Strengthen shared GitLab adapter guarantees before full lifecycle tests.

- [x] T005 [P] Add label transition safety tests in `elixir/test/symphony_elixir/gitlab_test.exs`
- [x] T006 [P] Add token boundary tests proving Codex runtime settings do not include GitLab tokens in `elixir/test/symphony_elixir/gitlab_test.exs`
- [x] T007 [P] Add terminal-over-active label derivation tests in `elixir/test/symphony_elixir/gitlab_test.exs`
- [x] T008 Add adapter writeback error behavior tests in `elixir/test/symphony_elixir/gitlab_test.exs`

**Checkpoint**: GitLab adapter primitives are independently tested.

---

## Phase 3: User Story 1 - Queue an Issue from GitLab (Priority: P1)

**Goal**: `/soc run` queues an eligible GitLab issue exactly once and writes acknowledgement through the adapter.

**Independent Test**: Replay a valid GitLab Note Hook payload and verify one queue label transition plus one acknowledgement comment.

- [x] T009 [P] [US1] Add webhook contract tests for missing, invalid, and valid `X-Gitlab-Token` in `elixir/test/symphony_elixir/gitlab_test.exs`
- [x] T010 [P] [US1] Add command parser tests for beginning-of-line command handling in `elixir/test/symphony_elixir/gitlab_test.exs`
- [x] T011 [US1] Add closed issue and already-running rejection tests in `elixir/test/symphony_elixir/gitlab_test.exs`
- [x] T012 [US1] Ensure `/soc run` accepted path writes queued label and acknowledgement comment in `elixir/lib/symphony_elixir/gitlab/webhook.ex`
- [x] T013 [US1] Ensure known unimplemented commands return clean comments without queueing in `elixir/lib/symphony_elixir/gitlab/webhook.ex`

**Checkpoint**: User Story 1 can be tested without orchestrator dispatch.

---

## Phase 4: User Story 2 - Dispatch and Complete a Queued Issue (Priority: P1)

**Goal**: Polling discovers queued GitLab issues, dispatch starts a run, and normal completion moves the issue to human review with a comment.

**Independent Test**: Use fake GitLab client and fake agent runner behavior to verify queued issue discovery through completion.

- [x] T014 [P] [US2] Add polling discovery test for GitLab active labels in `elixir/test/symphony_elixir/gitlab_test.exs`
- [x] T015 [US2] Add orchestrator lifecycle test for `soc::queued` to `soc::running` in `elixir/test/symphony_elixir/gitlab_lifecycle_test.exs`
- [x] T016 [US2] Add orchestrator normal completion test for `soc::human-review` and completion comment in `elixir/test/symphony_elixir/gitlab_lifecycle_test.exs`
- [x] T017 [US2] Implement missing adapter-owned completion comment in `elixir/lib/symphony_elixir/orchestrator.ex`
- [x] T018 [US2] Verify no GitLab write token is passed to agent execution in `elixir/test/symphony_elixir/gitlab_lifecycle_test.exs`

**Checkpoint**: Normal lifecycle is reproducible end to end with fakes.

---

## Phase 5: User Story 3 - Handle Failures and Duplicates Safely (Priority: P1)

**Goal**: Duplicate deliveries and agent failures do not create duplicate runs and leave auditable GitLab state.

**Independent Test**: Replay duplicate webhook payloads and simulate failures while checking writeback counts.

- [x] T019 [P] [US3] Add duplicate webhook delivery test with no duplicate comments or labels in `elixir/test/symphony_elixir/gitlab_test.exs`
- [x] T020 [US3] Add duplicate run prevention test from claimed/running labels in `elixir/test/symphony_elixir/gitlab_test.exs`
- [x] T021 [US3] Add orchestrator failure lifecycle test for `soc::failed` and failure comment in `elixir/test/symphony_elixir/gitlab_lifecycle_test.exs`
- [x] T022 [US3] Implement missing adapter-owned failure comment in `elixir/lib/symphony_elixir/orchestrator.ex`
- [x] T023 [US3] Document in-memory idempotency restart limitation in `elixir/README.md`

**Checkpoint**: Failure and duplicate behavior is reproducible and auditable.

---

## Phase 6: User Story 4 - Operate with Clear Setup and Boundaries (Priority: P2)

**Goal**: Maintainers can configure and demo GitLab control-plane behavior from documentation.

**Independent Test**: Follow `quickstart.md` or README setup without reading source code.

- [x] T024 [P] [US4] Expand GitLab token scope documentation in `elixir/README.md`
- [x] T025 [P] [US4] Expand webhook setup and label setup documentation in `elixir/README.md`
- [x] T026 [P] [US4] Add sample issue/comment workflow and known limitations in `elixir/README.md`
- [x] T027 [US4] Cross-link `specs/001-gitlab-control-plane/quickstart.md` from `elixir/README.md`

**Checkpoint**: Documentation supports configuration and demo.

---

## Phase 7: Clean-Room and Final Validation

**Purpose**: Verify the implementation matches the spec and does not violate reference-only constraints.

- [x] T028 Run `rg -n "/workspaces/reference|Dripmaster|symphony-py" elixir/lib elixir/test elixir/README.md specs/001-gitlab-control-plane --glob '!tasks.md' --glob '!plan.md'`
- [x] T029 Run `git diff --check` from repository root
- [x] T030 Run `mix format --check-formatted` in `elixir/`
- [x] T031 Run `mix specs.check` in `elixir/`
- [x] T032 Run `mix test test/symphony_elixir/gitlab_test.exs test/symphony_elixir/gitlab_lifecycle_test.exs` in `elixir/`
- [x] T033 Run the relevant full suite in `elixir/` and document any remaining unrelated failures with an upstream-safe fix

---

## Dependencies & Execution Order

### Phase Dependencies

- Phase 1 must complete before claiming any full-suite status.
- Phase 2 must complete before lifecycle stories because adapter safety is shared.
- Phases 3, 4, and 5 are all P1, but the recommended order is queueing, normal lifecycle, then failure/duplicates.
- Phase 6 can proceed in parallel after the final behavior is settled.
- Phase 7 is final validation.

### User Story Dependencies

- **US1** has no dependency on orchestrator dispatch and is the MVP.
- **US2** depends on US1 queue semantics and Phase 2 adapter safety.
- **US3** depends on US1 and US2 lifecycle observability.
- **US4** depends on final behavior details from US1-US3.

### Parallel Opportunities

- T005, T006, T007 can run in parallel.
- T009 and T010 can run in parallel.
- Documentation tasks T024, T025, T026 can run in parallel after behavior is stable.
- Final validation commands T028-T031 can run in parallel when implementation is complete.

## Implementation Strategy

### MVP First

1. Complete Phase 1.
2. Complete Phase 2.
3. Complete Phase 3 for `/soc run` queueing.
4. Stop and validate US1 independently.

### Stabilization Completion

After MVP, implement US2 and US3 lifecycle tests and missing comment writeback, then update documentation and run final validation.

### Future Features

Do not implement Cortex integration, responder actions, IOC enrichment, endpoint isolation, automatic blocking, SOC UI, branch creation, or merge request creation in this task set.

---

## Stage 3: Operational Hardening Tasks

**Baseline**: Stage 2 live staging validation completed. The Stage 3 objective is restart-safe, idempotent, documented GitLab control-plane operation without adding Cortex, responder actions, SOC UI, branch creation, or merge request creation.

### Phase 8: Persistent State Foundation

**Purpose**: Add durable single-node control-plane state before changing webhook or writeback behavior.

- [ ] T034 Add `tracker.state_path`, `tracker.writeback_max_attempts`, and `tracker.writeback_base_backoff_ms` config fields in `elixir/lib/symphony_elixir/config/schema.ex`
- [ ] T035 Add a file-backed GitLab state store in `elixir/lib/symphony_elixir/gitlab/state_store.ex`
- [ ] T036 Start the GitLab state store under the application supervisor in `elixir/lib/symphony_elixir.ex`
- [ ] T037 Add test support for per-test GitLab state paths in `elixir/test/support/test_support.exs`

### Phase 9: Restart-Safe Webhook Idempotency

**Independent Test**: Process a webhook, restart or reset the state-store process, replay the same event, and observe no duplicate label or comment writeback.

- [ ] T038 [P] Add persistent webhook replay tests in `elixir/test/symphony_elixir/gitlab_test.exs`
- [ ] T039 Replace ETS-only webhook idempotency with persistent state-store records in `elixir/lib/symphony_elixir/gitlab/webhook.ex`
- [ ] T040 Record webhook audit outcomes for handled, ignored, duplicate, and failed deliveries in `elixir/lib/symphony_elixir/gitlab/webhook.ex`

### Phase 10: Idempotent Lifecycle Writeback

**Independent Test**: Re-run completion and failure lifecycle handlers after state-store restart and verify no duplicate lifecycle comments or transitions.

- [ ] T041 [P] Add restart-safe lifecycle comment tests in `elixir/test/symphony_elixir/gitlab_lifecycle_test.exs`
- [ ] T042 Add idempotent adapter writeback helpers in `elixir/lib/symphony_elixir/gitlab/adapter.ex`
- [ ] T043 Route acknowledgement, completion, failure, and lifecycle transition writebacks through idempotent adapter helpers in `elixir/lib/symphony_elixir/gitlab/webhook.ex` and `elixir/lib/symphony_elixir/orchestrator.ex`

### Phase 11: Bounded GitLab Writeback Retry

**Independent Test**: Simulate retryable GitLab writeback failures followed by success and exhausted failure, verifying attempt counts and persistent audit records.

- [ ] T044 [P] Add writeback retry success and exhaustion tests in `elixir/test/symphony_elixir/gitlab_test.exs`
- [ ] T045 Implement bounded retry/backoff for GitLab issue comments and label updates in `elixir/lib/symphony_elixir/gitlab/client.ex`
- [ ] T046 Persist exhausted writeback audit records in `elixir/lib/symphony_elixir/gitlab/state_store.ex`

### Phase 12: Production-Readiness Documentation

- [ ] T047 Update GitLab operational documentation in `elixir/README.md`
- [ ] T048 Update `specs/001-gitlab-control-plane/quickstart.md` with persistent state and recovery notes
- [ ] T049 Update `specs/001-gitlab-control-plane/live-staging-validation.md` known risks to reflect Stage 3 behavior

### Phase 13: Stage 3 Validation

- [ ] T050 Run GitLab targeted tests in `elixir/`
- [ ] T051 Run full Elixir test suite in `elixir/`
- [ ] T052 Run `mix specs.check`, `mix format --check-formatted`, and `git diff --check`
- [ ] T053 Run clean-room search checks against implementation, tests, README, and specs
- [ ] T054 Re-run live staging validation against the disposable GitLab project, or document any environment blocker with exact commands and evidence
