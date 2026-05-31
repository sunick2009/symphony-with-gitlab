# Feature Specification: GitLab Control Plane Stabilization

**Feature Branch**: `001-gitlab-control-plane`

**Created**: 2026-05-29

**Status**: Stage 3 Operational Hardening

**Input**: Stabilize the GitLab control-plane lifecycle with a spec-defined `/soc run` workflow, label-based issue state, adapter-controlled writeback, duplicate delivery handling, lifecycle tests, documentation, and clean-room compliance. Stage 3 extends the completed Stage 2 baseline with persistent idempotency, restart-safe run-state, bounded GitLab API writeback retries, webhook audit records, and production-readiness documentation.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Queue an Issue from GitLab (Priority: P1)

A project maintainer comments `/soc run` on an eligible open GitLab issue and expects Symphony to validate the webhook, parse the command, queue the issue, update lifecycle labels, and acknowledge the request without exposing GitLab write credentials to the agent.

**Why this priority**: This is the primary user-visible control-plane action. Without it, GitLab cannot drive Symphony runs interactively.

**Independent Test**: Send a GitLab Note Hook payload for an open issue containing `/soc run` and verify that exactly one queue transition and one acknowledgement comment are produced by the adapter layer.

**Acceptance Scenarios**:

1. **Given** an open GitLab issue with an eligible workflow label, **When** a valid Note Hook with `/soc run` is received, **Then** Symphony validates the webhook secret, queues the issue with the configured queued label, and posts an acknowledgement comment through the adapter.
2. **Given** a comment body where `/soc run` is not at the beginning of a line, **When** the webhook is received, **Then** Symphony ignores it and performs no writeback.
3. **Given** a closed GitLab issue, **When** `/soc run` is received, **Then** Symphony rejects the command and posts a clear adapter-owned explanation without queuing the issue.

---

### User Story 2 - Dispatch and Complete a Queued Issue (Priority: P1)

An operator expects the orchestrator to discover queued GitLab issues, claim work safely, dispatch an agent run in an isolated workspace, and move the issue to human review on normal completion.

**Why this priority**: Queueing is incomplete unless the orchestrator lifecycle reaches a reproducible handoff state.

**Independent Test**: Configure the GitLab adapter with fake issue data and a fake agent runner outcome, then verify that discovery, dispatch, `soc::running`, and `soc::human-review` transitions occur in order.

**Acceptance Scenarios**:

1. **Given** a queued GitLab issue discovered by polling, **When** the orchestrator dispatches it, **Then** Symphony transitions the issue to `soc::running` through the adapter before or during dispatch.
2. **Given** a dispatched GitLab issue whose agent run completes normally, **When** the orchestrator processes completion, **Then** Symphony transitions the issue to `soc::human-review` and posts a completion summary through the adapter.
3. **Given** the agent requires operator input, **When** the run is blocked, **Then** Symphony transitions the issue to `soc::waiting-input` without releasing the issue for duplicate dispatch.

---

### User Story 3 - Handle Failures and Duplicates Safely (Priority: P1)

An operator expects duplicate webhooks, running issues, and agent failures to avoid duplicate runs while leaving an auditable GitLab state.

**Why this priority**: Duplicate dispatch and silent failures are the highest operational risks in a bot-controlled issue workflow.

**Independent Test**: Replay the same GitLab webhook delivery and simulate agent spawn or runtime failure; verify that duplicate delivery produces no duplicate writeback and failure moves the issue to `soc::failed`.

**Acceptance Scenarios**:

1. **Given** a webhook delivery already processed in the current service lifetime, **When** the same delivery is received again, **Then** Symphony returns duplicate status and performs no additional label update, comment, or run dispatch.
2. **Given** an issue already labeled with a Symphony lifecycle label such as `soc::queued`, `soc::claimed`, `soc::running`, `soc::waiting-input`, `soc::human-review`, `soc::failed`, or `soc::done`, **When** `/soc run` is received, **Then** Symphony rejects duplicate queueing and posts an explanatory comment.
3. **Given** a GitLab issue whose agent run fails, **When** the orchestrator handles the failure, **Then** Symphony transitions the issue to `soc::failed` and posts an adapter-owned failure summary.
4. **Given** Symphony restarts after processing a webhook delivery, **When** GitLab replays the same delivery, **Then** Symphony suppresses the replay from persistent state and performs no duplicate label transition, comment, or run dispatch.
5. **Given** Symphony restarts after a completion or failure comment has been written, **When** the same lifecycle handler is reached again, **Then** Symphony does not post a duplicate completion or failure comment.

---

### User Story 4 - Operate with Clear Setup and Boundaries (Priority: P2)

A repository maintainer configures GitLab token scopes, webhook secrets, labels, and demo steps from documentation without giving GitLab write tokens to the Codex agent.

**Why this priority**: The control plane must be deployable and reviewable by maintainers before future SOC capabilities are considered.

**Independent Test**: Follow the quickstart using fake local adapter modules or a test GitLab project and verify that required labels, token scopes, webhook event types, and limitations are documented.

**Acceptance Scenarios**:

1. **Given** a maintainer reading the docs, **When** they configure GitLab support, **Then** they can identify required token scope, webhook secret, labels, endpoint, and project slug.
2. **Given** a maintainer evaluating safety, **When** they review the docs and spec, **Then** they can confirm that GitLab mutation is adapter-owned and not performed by Codex.
3. **Given** future SOC feature requests, **When** they inspect the plan, **Then** they can see Cortex, IOC enrichment, responder actions, endpoint isolation, automatic blocking, and SOC UI listed as future features.

### User Story 5 - Recover from GitLab Writeback Interruptions (Priority: P1)

An operator expects temporary GitLab API failures during label or comment writeback to be retried with bounded backoff, recorded for audit, and surfaced clearly when retries are exhausted.

**Why this priority**: GitLab writeback is the only mutation path for the control plane. Unbounded retry can stall the service, while no retry makes transient GitLab failures look like workflow failures.

**Independent Test**: Simulate transient GitLab API failures followed by success and permanent failures after all attempts; verify retry count, backoff bounds, state-store audit records, and final adapter return values.

**Acceptance Scenarios**:

1. **Given** a GitLab label transition fails with a retryable API error, **When** a later bounded retry succeeds, **Then** Symphony records the writeback as complete and does not repeat it on restart.
2. **Given** a GitLab comment writeback fails for all configured attempts, **When** retries are exhausted, **Then** Symphony records the failed writeback with attempt count and returns a clear error to the caller.
3. **Given** a writeback has already completed, **When** the same lifecycle transition or lifecycle comment is requested again after restart, **Then** Symphony treats it as already complete and performs no GitLab mutation.

### Edge Cases

- Missing, invalid, or mismatched GitLab webhook secret.
- GitLab Note Hook for a merge request, snippet, or unsupported noteable type.
- Unsupported `/soc` command.
- Multiple `/soc` commands in one comment.
- Issue labels include both active and terminal workflow labels.
- GitLab API writeback fails during queue, running, completion, or failure transitions.
- Service restart after a webhook delivery, queue transition, completion comment, or failure comment.
- Persistent state file is missing, unreadable, malformed, or stored on ephemeral storage.
- GitLab issue IID is missing from a webhook payload.
- Reference-only repository materials are present in the workspace but must not influence implementation beyond conceptual notes.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Symphony MUST support `tracker.kind: gitlab` as a first-class tracker option for the control-plane foundation.
- **FR-002**: Symphony MUST read GitLab issues by configured active labels and normalize them into the existing issue model used by the orchestrator.
- **FR-003**: Symphony MUST derive GitLab issue workflow state from labels, with terminal labels taking precedence over active labels.
- **FR-004**: Symphony MUST validate GitLab webhook requests using the configured secret before parsing commands or performing writeback.
- **FR-005**: Symphony MUST parse `/soc run`, `/soc status`, `/soc retry`, and `/soc cancel` only when commands appear at the beginning of a line.
- **FR-006**: Symphony MUST treat `/soc run` as the only dispatch-triggering command in this phase.
- **FR-007**: Symphony MUST reject `/soc run` for closed issues and issues already in a Symphony lifecycle state that should not create a duplicate run.
- **FR-008**: Symphony MUST perform GitLab comments and label mutations only through the GitLab adapter layer.
- **FR-009**: Symphony MUST NOT require or pass GitLab write tokens to Codex agent turns.
- **FR-010**: Symphony MUST transition labels for queue, running, waiting-input, human-review, and failed lifecycle states through adapter-controlled writeback.
- **FR-011**: Symphony MUST post an adapter-owned acknowledgement comment when `/soc run` is accepted.
- **FR-012**: Symphony MUST post adapter-owned completion and failure comments for GitLab runs.
- **FR-013**: Symphony MUST avoid duplicate writeback for duplicate webhook deliveries within the same service lifetime.
- **FR-014**: Symphony MUST provide tests for polling discovery, webhook `/soc run`, label state derivation, label transition safety, comment writeback, failure handling, duplicate webhook handling, and token boundary behavior.
- **FR-015**: Symphony MUST document GitLab token scopes, webhook setup, label setup, sample issue/comment workflow, known limitations, future phases, and clean-room compliance.
- **FR-016**: Symphony MUST maintain clean-room constraints by not copying code, tests, docs, comments, names, or file structure from reference-only repositories.
- **FR-017**: Symphony MUST persist GitLab webhook idempotency records so replayed deliveries after process restart do not perform duplicate label updates, comments, or run dispatch.
- **FR-018**: Symphony MUST persist GitLab lifecycle writeback completion records so normal completion and failure handlers do not create duplicate completion or failure comments after restart.
- **FR-019**: Symphony MUST persist GitLab run-state/audit records for webhook processing and adapter-owned writebacks without storing GitLab API tokens or webhook secrets.
- **FR-020**: Symphony MUST retry GitLab API writeback operations with configurable maximum attempts and bounded exponential backoff.
- **FR-021**: Symphony MUST record exhausted GitLab writeback failures in persistent state with operation type, issue IID, attempt count, status, and timestamp.
- **FR-022**: Symphony MUST expose configuration for the persistent GitLab control-plane state path and use a deterministic safe default when not configured.
- **FR-023**: Repository setup MUST track the Spec Kit assets required to reproduce this feature workflow while excluding local secrets, runtime state, staging evidence, generated noise, and unreviewed local environment experiments.
- **FR-024**: Live staging validation MUST support a real local Codex app-server run and verify that GitLab API tokens and webhook secrets are absent from that runner process.
- **FR-025**: GitLab reconciliation MUST keep an in-progress agent alive while its issue carries `soc::claimed`, `soc::running`, or `soc::waiting-input`, without broadening polling discovery beyond configured candidate labels.

### Key Entities *(include if feature involves data)*

- **GitLab Issue**: A project issue identified by GitLab project slug and issue IID, with title, description, labels, open/closed state, URL, timestamps, and derived Symphony lifecycle state.
- **GitLab Webhook Delivery**: A GitLab event request with event type, secret token, event UUID or object ID, and payload.
- **Persistent Control-Plane State**: Local durable state containing webhook delivery audit records, issue run-state markers, and idempotent writeback completion/failure records. It must not contain GitLab API tokens, webhook secrets, issue bodies, or agent output.
- **Bot Command**: A line-starting `/soc` command parsed from an issue comment.
- **Lifecycle Transition**: An adapter-owned label update that adds one target lifecycle label and removes conflicting lifecycle labels.
- **Run Lifecycle Event**: A queue, dispatch, completion, waiting-input, or failure event emitted by the webhook handler or orchestrator.
- **Adapter Writeback**: A comment or label mutation performed by the GitLab adapter using GitLab credentials unavailable to Codex.
- **Writeback Attempt**: One bounded GitLab API mutation attempt, including retryable failures and final completion or exhaustion.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A local automated test can replay a `/soc run` webhook and observe one accepted queue transition plus one acknowledgement comment.
- **SC-002**: A local automated test can run a fake GitLab issue through dispatch and normal completion to `soc::human-review`.
- **SC-003**: A local automated test can simulate agent failure and observe `soc::failed` plus a failure comment.
- **SC-004**: Duplicate delivery tests show zero duplicate label updates, comments, or dispatches for the same delivery in the same service lifetime.
- **SC-005**: The relevant Elixir test suite, including GitLab lifecycle tests and previously failing core workspace tests, passes or has a documented unrelated failure with an upstream-safe fix.
- **SC-006**: Documentation is sufficient for a maintainer to configure labels, token scope, webhook secret, endpoint, project slug, and a demo `/soc run` workflow without reading source code.
- **SC-007**: Review of diffs and search results confirms no copied files or code from the reference-only repository.
- **SC-008**: A local automated test can restart the GitLab state store after a processed webhook and prove replayed delivery is suppressed without duplicate writeback.
- **SC-009**: A local automated test can restart after a lifecycle completion or failure writeback and prove duplicate lifecycle comments are not posted.
- **SC-010**: A local automated test can simulate retryable GitLab writeback failures and observe bounded retry followed by either success or audited exhaustion.
- **SC-011**: Stage 3 documentation explains persistent state placement, backup/retention expectations, token rotation, webhook endpoint deployment, failure recovery, and secret handling.
- **SC-012**: A real local Codex app-server staging run reaches `soc::human-review`, and environment trace evidence shows that `GITLAB_API_TOKEN` and `GITLAB_WEBHOOK_SECRET` are absent from the Codex process.
- **SC-013**: A lifecycle test spans at least one polling reconciliation cycle while the issue carries `soc::running` and still completes to `soc::human-review`.

## Assumptions

- GitLab REST project issue IID is the tracker issue ID for the first control-plane milestone.
- Stage 2 live staging results are the baseline; Stage 3 replaces in-memory-only idempotency with local persistent state.
- The existing Elixir tracker boundary remains the primary integration point.
- Completion and failure summaries can be concise adapter-owned comments in this phase.
- A local file-backed state store is acceptable for Stage 3 hardening because the current service has no database dependency; future production deployments may replace it with a stronger shared store.
- Branch creation and merge request creation are future work.
- Cortex integration, IOC enrichment, responder actions, SOC UI, endpoint isolation, and automatic production-impacting actions are out of scope.
