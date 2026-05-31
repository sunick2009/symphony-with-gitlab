# Tasks: GitLab Merge Request Workflow

**Input**: Design documents from `specs/002-gitlab-mr-workflow/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: Required. Stage 4 introduces repository mutation and CI reconciliation and must be covered by focused adapter and lifecycle tests before staging validation.

**Organization**: Tasks are grouped by independently testable user stories.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel because it touches different files or independent tests.
- **[Story]**: User story label from `spec.md`.
- Every task includes an exact file path.

## Phase 1: Setup and Design Anchoring

**Purpose**: Establish Stage 4 documentation and validation baseline before implementation.

- [x] T001 Record the chosen Stage 4 repository mutation strategy and security rationale in `specs/002-gitlab-mr-workflow/research.md`
- [x] T002 Extend Stage 4 planning notes for required GitLab APIs, staging boundaries, and CI reconciliation in `specs/002-gitlab-mr-workflow/plan.md`
- [x] T003 Add Stage 4 overview and staging-only warning to `elixir/README.md`

---

## Phase 2: Foundational Stage 4 Infrastructure

**Purpose**: Add the shared adapter and persistence primitives required by all user stories.

- [x] T004 Define Stage 4 repository mutation state structures in `elixir/lib/symphony_elixir/gitlab/state_store.ex`
- [x] T005 [P] Extend GitLab client request helpers for branch, commit, merge request, and MR pipeline APIs in `elixir/lib/symphony_elixir/gitlab/client.ex`
- [x] T006 [P] Add adapter-owned Stage 4 mutation entrypoints in `elixir/lib/symphony_elixir/gitlab/adapter.ex`
- [x] T007 Add a dedicated Stage 4 workflow coordinator in `elixir/lib/symphony_elixir/gitlab/mr_workflow.ex`
- [x] T008 Add foundational fake-client coverage for Stage 4 API operations in `elixir/test/symphony_elixir/gitlab_mr_workflow_test.exs`

**Checkpoint**: Shared Stage 4 mutation and persistence primitives exist without changing orchestrator behavior yet.

---

## Phase 3: User Story 1 - Create a Reviewable Merge Request from an Issue (Priority: P1) 🎯 MVP

**Goal**: A successful GitLab issue run produces one adapter-owned branch, commit, merge request, and issue link writeback.

**Independent Test**: Drive a successful run to completion with a controlled artifact manifest and verify one branch, one commit, one MR, one issue note, and `soc::human-review`.

### Tests for User Story 1

- [ ] T009 [P] [US1] Add Stage 4 branch naming and artifact collection tests in `elixir/test/symphony_elixir/gitlab_mr_workflow_test.exs`
- [x] T009 [P] [US1] Add Stage 4 branch naming and artifact collection tests in `elixir/test/symphony_elixir/gitlab_mr_workflow_test.exs`
- [x] T010 [P] [US1] Add successful branch, commit, MR creation tests in `elixir/test/symphony_elixir/gitlab_mr_workflow_test.exs`
- [x] T011 [US1] Add orchestrator completion coverage for Stage 4 handoff in `elixir/test/symphony_elixir/gitlab_lifecycle_test.exs`

### Implementation for User Story 1

- [x] T012 [P] [US1] Implement adapter-owned artifact manifest collection in `elixir/lib/symphony_elixir/gitlab/mr_workflow.ex`
- [x] T013 [P] [US1] Implement deterministic branch naming and provenance checks in `elixir/lib/symphony_elixir/gitlab/mr_workflow.ex`
- [x] T014 [US1] Implement Branches API and Commits API repository mutation flow in `elixir/lib/symphony_elixir/gitlab/client.ex`
- [x] T015 [US1] Implement merge request creation and issue-link writeback in `elixir/lib/symphony_elixir/gitlab/mr_workflow.ex`
- [x] T016 [US1] Trigger Stage 4 MR finalization from normal GitLab run completion in `elixir/lib/symphony_elixir/orchestrator.ex`

**Checkpoint**: Stage 4 can create a reviewable merge request and move the issue to `soc::human-review`.

---

## Phase 4: User Story 2 - Reflect CI Status Back to the Issue and Merge Request (Priority: P1)

**Goal**: CI state for the adapter-created MR is reconciled back to the issue through idempotent writeback.

**Independent Test**: Simulate MR pipeline status progression and verify the correct issue writeback and lifecycle mapping.

### Tests for User Story 2

- [ ] T017 [P] [US2] Add MR pipeline status normalization tests in `elixir/test/symphony_elixir/gitlab_mr_workflow_test.exs`
- [ ] T018 [P] [US2] Add CI success and failure reconciliation tests in `elixir/test/symphony_elixir/gitlab_mr_workflow_test.exs`
  Note: CI failure writeback helper coverage exists; full reconciliation coverage remains incomplete.
- [ ] T019 [US2] Add lifecycle coverage for Stage 4 CI writeback in `elixir/test/symphony_elixir/gitlab_lifecycle_test.exs`

### Implementation for User Story 2

- [ ] T020 [P] [US2] Implement MR pipeline fetch and normalization helpers in `elixir/lib/symphony_elixir/gitlab/client.ex`
- [x] T020 [P] [US2] Implement MR pipeline fetch and normalization helpers in `elixir/lib/symphony_elixir/gitlab/client.ex`
- [ ] T021 [US2] Implement Stage 4 CI observation persistence and status-class dedupe in `elixir/lib/symphony_elixir/gitlab/state_store.ex`
- [ ] T022 [US2] Implement CI success and failure issue writeback flow in `elixir/lib/symphony_elixir/gitlab/mr_workflow.ex`
  Note: CI failure writeback helper exists; success flow and reconciliation integration remain incomplete.
- [ ] T023 [US2] Integrate CI reconciliation scheduling into `elixir/lib/symphony_elixir/orchestrator.ex`

**Checkpoint**: Stage 4 reflects CI status to the originating issue without duplicate comments.

---

## Phase 5: User Story 3 - Suppress Duplicate Repository Mutation Across Retries and Restarts (Priority: P1)

**Goal**: Partial failure, retry, and restart paths remain idempotent for repository mutation and issue writeback.

**Independent Test**: Restart or re-enter the workflow after branch creation, commit creation, MR creation, or issue writeback and verify no duplicate repository artifacts are created.

### Tests for User Story 3

- [x] T024 [P] [US3] Add branch reuse and duplicate MR suppression tests in `elixir/test/symphony_elixir/gitlab_mr_workflow_test.exs`
- [ ] T025 [P] [US3] Add restart-safe repository mutation resume tests in `elixir/test/symphony_elixir/gitlab_mr_workflow_test.exs`
  Note: same-digest dry-run idempotency and changed-digest conflict coverage exist; restart-safe live mutation resume remains incomplete.
- [ ] T026 [US3] Add partial writeback recovery coverage in `elixir/test/symphony_elixir/gitlab_lifecycle_test.exs`

### Implementation for User Story 3

- [x] T027 [P] [US3] Extend persistent writeback keys for Stage 4 branch, commit, MR, and CI operations in `elixir/lib/symphony_elixir/gitlab/state_store.ex`
- [ ] T028 [US3] Implement repository mutation lookup and provenance validation in `elixir/lib/symphony_elixir/gitlab/mr_workflow.ex`
- [ ] T029 [US3] Implement resume-from-first-incomplete-step logic in `elixir/lib/symphony_elixir/gitlab/mr_workflow.ex`
- [ ] T030 [US3] Extend adapter retry and exhausted-failure audit behavior for Stage 4 writeback in `elixir/lib/symphony_elixir/gitlab/client.ex`

**Checkpoint**: Stage 4 repository mutation is restart-safe and duplicate-resistant.

---

## Phase 6: User Story 4 - Operate Stage 4 Safely in Staging Only (Priority: P2)

**Goal**: Maintainers can configure and validate Stage 4 safely in a disposable staging project.

**Independent Test**: Follow the Stage 4 quickstart and staging script workflow without reading implementation code.

### Tests for User Story 4

- [x] T031 [P] [US4] Add token-boundary regression coverage for Stage 4 completion paths in `elixir/test/symphony_elixir/gitlab_lifecycle_test.exs`

### Implementation for User Story 4

- [x] T032 [P] [US4] Document Stage 4 token scopes, branch naming, and CI behavior in `elixir/README.md`
- [x] T033 [P] [US4] Add Stage 4 staging validation steps in `specs/002-gitlab-mr-workflow/quickstart.md`
- [x] T034 [US4] Extend the staging helper workflow for MR creation and CI observation in `specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh`
- [ ] T035 [US4] Record Stage 4 staging evidence and known risks in `specs/002-gitlab-mr-workflow/plan.md`

**Checkpoint**: Stage 4 is documented and staging validation is reproducible.

---

## Phase 7: Final Validation

**Purpose**: Verify Stage 4 matches the spec, preserves security boundaries, and is ready for staging-only validation.

- [ ] T036 Run targeted Stage 4 tests in `elixir/`
- [ ] T037 Run relevant full Elixir validation in `elixir/`
- [ ] T038 Run `mix specs.check`, `mix format --check-formatted`, and `git diff --check`
- [ ] T039 Run clean-room search checks against `elixir/lib`, `elixir/test`, `elixir/README.md`, and `specs/002-gitlab-mr-workflow`
- [ ] T040 Run Stage 4 disposable staging validation and record sanitized results in `specs/002-gitlab-mr-workflow/quickstart.md`

## Dependencies & Execution Order

### Phase Dependencies

- Phase 1 establishes documentation and must complete first.
- Phase 2 blocks all user story work because repository mutation primitives are shared.
- Phase 3 is the MVP and should complete before CI reconciliation.
- Phase 4 depends on successful MR creation from Phase 3.
- Phase 5 depends on observable Stage 4 mutation paths from Phases 3 and 4.
- Phase 6 can begin once core design decisions from Phases 3 and 4 are stable.
- Phase 7 is final validation.

### User Story Dependencies

- **US1** depends on Phase 2 only.
- **US2** depends on US1 because there is no MR to reconcile before MR creation exists.
- **US3** depends on US1 and US2 because resume logic must cover completed mutation and CI writeback paths.
- **US4** depends on stable behavior from US1-US3.

### Parallel Opportunities

- T005 and T006 can run in parallel after T004.
- T009 and T010 can run in parallel.
- T017 and T018 can run in parallel.
- T024 and T025 can run in parallel.
- Documentation tasks T032 and T033 can run in parallel.

## Implementation Strategy

### MVP First

1. Complete Phase 1.
2. Complete Phase 2.
3. Complete Phase 3 for branch, commit, and MR creation.
4. Stop and validate US1 independently.

### Incremental Delivery

After MVP, add CI reconciliation, then restart-safe duplicate suppression, then staging validation and documentation updates.

### Future Features

Do not implement Cortex integration, IOC enrichment, responder actions, SOC UI, production GitLab integration, auto-merge, auto-blocking, endpoint isolation, or agent-owned repository pushes in this task set.
