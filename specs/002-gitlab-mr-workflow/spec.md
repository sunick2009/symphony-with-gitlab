# Feature Specification: GitLab Merge Request Workflow

**Feature Branch**: `002-gitlab-mr-workflow`

**Created**: 2026-05-31

**Status**: Draft

**Input**: Define Stage 4 of the Symphony GitLab integration so an eligible GitLab issue can trigger a Codex run that produces adapter-owned branch, commit, merge request, CI status reflection, and issue writeback behavior in a disposable staging project without exposing GitLab write credentials to the Codex agent process.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Create a Reviewable Merge Request from an Issue (Priority: P1)

A maintainer comments `/agent run` on an eligible GitLab issue and expects Symphony to turn the agent output into a reviewable merge request without allowing the agent process to push branches or hold GitLab write credentials. The legacy `/soc run` command remains a backward-compatible alias.

**Why this priority**: This is the core Stage 4 value. Without adapter-owned branch, commit, and merge request creation, the workflow stops at local agent output and does not produce a reviewable artifact in GitLab.

**Independent Test**: Run a staged GitLab issue through `/agent run` with a fake or staging-safe artifact bundle and verify that exactly one adapter-owned branch, commit, merge request, and issue note are created for the run. Confirm that the legacy `/soc run` alias triggers the same workflow.

**Acceptance Scenarios**:

1. **Given** an eligible open GitLab issue and a successful Codex run that produces collected file outputs, **When** the adapter finalizes the run, **Then** Symphony creates one deterministic source branch, creates one commit on that branch, opens one merge request targeting the configured default branch, posts the MR link back to the issue, and transitions the issue to `soc::human-review`.
2. **Given** a successful Codex run whose collected output is empty after adapter validation, **When** Stage 4 finalization runs, **Then** Symphony records the no-change result, writes a clear issue note, and does not create a branch or merge request.
3. **Given** the same run finalization is retried after partial completion or process restart, **When** the adapter re-enters the branch/commit/MR workflow, **Then** Symphony reuses or suppresses already-completed repository mutations instead of creating duplicate branches, commits, or merge requests.

---

### User Story 2 - Reflect CI Status Back to the Issue and Merge Request (Priority: P1)

A maintainer expects the merge request created by Symphony to reflect CI progress, success, or failure back to the originating issue so the issue shows whether the generated change is ready for human review.

**Why this priority**: A generated merge request without pipeline visibility leaves the control plane incomplete and forces operators to inspect GitLab manually.

**Independent Test**: Create a merge request through the adapter, simulate pipeline status transitions, and verify that the issue receives exactly one idempotent writeback per status class and that the issue lifecycle mapping follows the spec.

**Acceptance Scenarios**:

1. **Given** an adapter-created merge request with a running pipeline, **When** Symphony refreshes the merge request status, **Then** it records pipeline status and posts or updates issue-facing progress without altering the token boundary.
2. **Given** the newest merge request pipeline succeeds, **When** Symphony processes the terminal CI result, **Then** the merge request remains open for human review, the issue stays in `soc::human-review`, and Symphony writes a success note referencing the MR.
3. **Given** the newest merge request pipeline fails or is canceled, **When** Symphony processes the terminal CI result, **Then** the merge request remains open, the issue remains operator-visible with an explicit failure writeback, and the failure is recorded for retry-safe reconciliation.

---

### User Story 3 - Suppress Duplicate Repository Mutation Across Retries and Restarts (Priority: P1)

An operator expects repeated reconciliations, webhook replays, or transient GitLab failures not to create duplicate branches, duplicate merge requests, or conflicting issue comments.

**Why this priority**: Repository mutation is more expensive and harder to clean up than issue comments. Duplicate MR creation would undermine trust in the integration quickly.

**Independent Test**: Simulate restart, retry, and partial-success conditions around branch creation, commit creation, merge request creation, and issue writeback, then verify that repository mutation remains single-shot and auditable.

**Acceptance Scenarios**:

1. **Given** a branch already exists for a run fingerprint, **When** branch creation is retried, **Then** Symphony verifies ownership metadata and reuses the existing branch instead of creating a second one.
2. **Given** an open merge request already exists for the generated source branch, **When** merge request creation is retried, **Then** Symphony reuses that merge request and does not create another one.
3. **Given** branch creation and commit creation succeeded but issue writeback failed, **When** reconciliation resumes later, **Then** Symphony completes only the missing writeback steps and records the final result without repeating repository writes.

---

### User Story 4 - Operate Stage 4 Safely in Staging Only (Priority: P2)

A maintainer needs clear documentation for the additional GitLab permissions, staging-only validation steps, and security tradeoffs before enabling branch and merge request creation.

**Why this priority**: Stage 4 introduces repository mutation. The setup, scope, and validation boundaries must be explicit before any implementation is considered acceptable.

**Independent Test**: Follow the Stage 4 quickstart against a disposable staging project and verify that token scopes, branch naming, output collection constraints, CI polling expectations, and staging-only guardrails are documented without reading source code.

**Acceptance Scenarios**:

1. **Given** a maintainer reading the docs, **When** they prepare Stage 4 staging validation, **Then** they can identify required token scopes, allowed project type, required labels, MR target branch expectations, and prohibited production usage.
2. **Given** a maintainer reviewing the security model, **When** they inspect the spec and plan, **Then** they can confirm that GitLab write tokens remain adapter-owned and are never injected into the Codex runner environment.
3. **Given** a maintainer reviewing implementation boundaries, **When** they inspect the plan and tasks, **Then** they can see that Cortex, IOC enrichment, responder actions, SOC UI, and production-impacting automation remain out of scope.

### Edge Cases

- Agent output contains no file changes after adapter filtering.
- Agent output includes file paths outside the allowed workspace or repository root.
- Branch creation succeeds but commit creation fails.
- Commit creation succeeds but merge request creation fails.
- Merge request creation succeeds but issue note writeback fails.
- The source branch already exists with different provenance metadata than the current run.
- An open merge request exists for the same source branch but points to an unexpected target branch.
- CI creates multiple pipelines for the same merge request and only the newest relevant pipeline should drive issue status.
- GitLab API retries exhaust during repository mutation or issue writeback.
- Staging validation is attempted against a non-disposable or production project.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Symphony MUST preserve the Stage 1-3.5 token boundary where GitLab write credentials remain exclusively in the adapter and client layer.
- **FR-002**: Symphony MUST collect agent-produced changes only from adapter-approved workspace outputs and MUST reject paths outside the isolated workspace or repository root.
- **FR-003**: Symphony MUST define a deterministic branch naming scheme derived from project-controlled metadata that includes at least the issue IID and a run-specific fingerprint.
- **FR-004**: Symphony MUST create GitLab branches, commits, and merge requests through adapter-owned mutation paths and MUST NOT require the agent process to execute `git push` with GitLab credentials.
- **FR-005**: Symphony MUST document the required GitLab token scopes and justify each scope used by the Stage 4 workflow.
- **FR-006**: Symphony MUST suppress duplicate branch creation across retries and process restarts using persistent idempotency records plus source-branch lookup or provenance verification.
- **FR-007**: Symphony MUST suppress duplicate merge request creation across retries and process restarts by looking up existing open merge requests for the deterministic source branch before creating a new one.
- **FR-008**: Symphony MUST persist adapter-owned Stage 4 mutation records for branch creation, commit creation, merge request creation, CI observation, and issue writeback without storing GitLab secrets or raw agent prompts.
- **FR-009**: Symphony MUST write the merge request web URL and initial status back to the originating GitLab issue through adapter-owned issue notes.
- **FR-010**: Symphony MUST transition the issue to `soc::human-review` after a merge request is successfully created and linked back to the issue.
- **FR-011**: Symphony MUST record and reconcile CI status for the adapter-created merge request in staging, including at least pending or running, success, and failure or canceled outcomes.
- **FR-012**: Symphony MUST keep the merge request open for human review after CI success or failure; Stage 4 MUST NOT auto-merge or auto-close merge requests.
- **FR-013**: Symphony MUST define how CI outcomes affect issue state and writeback. CI success keeps the issue in `soc::human-review`; CI failure writes a failure summary and keeps the issue visible for operator decision instead of performing production-impacting automation.
- **FR-014**: Symphony MUST retry or record exhausted failures for Stage 4 issue writeback and CI writeback operations using the existing bounded adapter retry model.
- **FR-015**: Symphony MUST choose one repository mutation strategy for Stage 4 and document its security tradeoff against the rejected alternative.
- **FR-016**: Stage 4 MUST use only a disposable staging GitLab project for live validation and MUST NOT connect to production GitLab projects.
- **FR-017**: Stage 4 documentation MUST explain how generated files or patch content are collected from the agent workspace, normalized into commit actions, and validated before repository mutation.
- **FR-018**: Stage 4 MUST define deterministic commit message and merge request title or description conventions that reference the originating issue.
- **FR-019**: Stage 4 MUST provide automated tests for successful branch/commit/MR creation, duplicate suppression, CI status reconciliation, and token-boundary preservation.
- **FR-020**: Stage 4 MUST preserve clean-room constraints and update feature documentation before implementation code changes begin.

### Key Entities *(include if feature involves data)*

- **Stage 4 Run Artifact Set**: The adapter-approved set of generated files, patch content, metadata, and commit intent emitted from the isolated agent workspace for one run.
- **Repository Mutation Record**: Persistent state describing branch creation, commit creation, and merge request creation attempts, ownership markers, attempt counts, timestamps, and final status.
- **Branch Provenance Marker**: Deterministic metadata that ties a branch to a specific GitLab issue IID and run fingerprint so retries can verify reuse safely.
- **Merge Request Projection**: The stored MR IID, web URL, source branch, target branch, title, and latest observed CI status associated with one issue run.
- **CI Observation**: A normalized record of the newest relevant merge request pipeline status and the last issue writeback emitted for that status class.
- **Issue Writeback Record**: Adapter-owned note or label mutation metadata used to avoid duplicate MR-link, CI-success, and CI-failure comments.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A targeted automated test can drive a successful Stage 4 run from queued issue to adapter-created branch, commit, merge request, and `soc::human-review` without exposing GitLab write credentials to the agent runtime.
- **SC-002**: A targeted automated test can retry Stage 4 repository finalization after a simulated restart and observe zero duplicate branches and zero duplicate merge requests.
- **SC-003**: A targeted automated test can simulate merge request CI success and observe exactly one success writeback to the issue.
- **SC-004**: A targeted automated test can simulate merge request CI failure and observe exactly one failure writeback to the issue while the merge request remains open.
- **SC-005**: Staging validation can complete against a disposable GitLab project using documented Stage 4 setup and without using a production project.
- **SC-006**: Review of runtime settings and runner environment shows that GitLab write tokens and webhook secrets remain absent from the Codex process during Stage 4 validation.
- **SC-007**: Documentation is sufficient for a maintainer to explain token scopes, branch naming, output collection, repository mutation strategy, CI reconciliation, retry behavior, and staging-only boundaries without reading source code.

## Assumptions

- The existing Stage 3 persistent state store is the starting point for Stage 4 idempotency, but it must be extended with repository mutation records.
- Stage 4 continues to target a single disposable GitLab project rather than multi-project or multi-node production deployment.
- The GitLab repository being mutated is the same project that owns the originating issue for this phase.
- The initial Stage 4 implementation will handle text files and deterministic generated artifacts before attempting large binary asset workflows.
- Human reviewers, not the agent, remain responsible for merge approval and final merge decisions.
