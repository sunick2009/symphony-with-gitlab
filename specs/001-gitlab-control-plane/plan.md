# Implementation Plan: GitLab Control Plane Stabilization

**Branch**: `001-gitlab-control-plane` | **Date**: 2026-05-29 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/001-gitlab-control-plane/spec.md`

## Summary

Stabilize the GitLab control-plane foundation so a GitLab issue comment can request `/soc run`, the adapter validates and queues the issue, the orchestrator discovers and dispatches it, lifecycle labels and comments are written only by the adapter, and normal completion, failure, and duplicate delivery behavior are covered by tests and documentation.

The current implementation already includes initial GitLab tracker routing, a REST client, webhook controller, command parser, adapter writeback, and partial lifecycle label updates. The stabilization phase must close the documented gaps before expanding scope.

## Technical Context

**Language/Version**: Elixir 1.19.x on OTP 28, as configured by `elixir/mise.toml`

**Primary Dependencies**: Phoenix/Bandit for the optional HTTP server, Req for outbound HTTP, Ecto changesets for config validation, ExUnit for tests

**Storage**: In-memory orchestrator state plus file-backed GitLab control-plane state for webhook idempotency, lifecycle writeback completion, and audit records; no database dependency in Stage 3

**Testing**: ExUnit targeted tests plus relevant full-suite validation under `elixir/`

**Target Platform**: Long-running Symphony Elixir service in trusted evaluation environments

**Project Type**: Elixir service with optional HTTP API and dashboard

**Performance Goals**: Webhook processing should be bounded by local validation plus GitLab API writeback latency; polling should avoid unbounded duplicate issue dispatch

**Constraints**: GitLab mutation stays in adapter layer; Codex agent does not receive GitLab write tokens; reference-only repository code must not be copied; no Cortex, responder actions, IOC enrichment, SOC UI, endpoint isolation, automatic blocking, branch creation, or merge request creation

**Scale/Scope**: Single configured GitLab project for this phase, project issue IIDs as tracker IDs, persistent local idempotency for one Symphony deployment

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- Official Repository Authority: Pass. All planned changes target the official Symphony Elixir implementation.
- Adapter-Owned Tracker Mutation: Pass. GitLab label and comment mutation remains in the GitLab adapter/client path.
- Spec-Driven Lifecycle Changes: Pass. This plan documents current gaps before additional implementation.
- Testable Control Plane: Pass with required task follow-up. Existing tests cover initial webhook and parser behavior; full lifecycle tests remain to be added.
- Narrow Scope and Future SOC Boundary: Pass. Future SOC capabilities are explicitly excluded.

## Current Implementation Gaps

1. Completion and failure lifecycle comments are not yet implemented; current lifecycle mapping only updates labels.
2. End-to-end orchestrator tests do not yet prove webhook queueing flows into polling discovery, dispatch, completion, failure, and duplicate suppression.
3. Duplicate `/soc run` prevention is currently webhook-delivery scoped and label-state scoped, but there is no test that duplicate queueing cannot create duplicate orchestrator dispatches.
4. Label transition safety needs stronger tests for removing conflicting lifecycle labels while preserving unrelated labels.
5. Full-suite validation is blocked by an existing workspace hook shell compatibility failure in `core_test.exs:1003` and related agent-runner tests.
6. Documentation needs a more complete GitLab setup/demo section, including token scopes, webhook events, labels, known limitations, and future phases.
7. Clean-room compliance is documented but should be re-verified before final handoff with diff and search checks.

## Project Structure

### Documentation (this feature)

```text
specs/001-gitlab-control-plane/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── gitlab-webhook.md
├── checklists/
│   └── requirements.md
└── tasks.md
```

### Source Code

```text
elixir/
├── lib/symphony_elixir/
│   ├── config.ex
│   ├── config/schema.ex
│   ├── gitlab/
│   │   ├── adapter.ex
│   │   ├── client.ex
│   │   ├── command.ex
│   │   └── webhook.ex
│   ├── orchestrator.ex
│   └── tracker.ex
├── lib/symphony_elixir_web/
│   ├── controllers/gitlab_webhook_controller.ex
│   └── router.ex
└── test/
    ├── support/test_support.exs
    └── symphony_elixir/
        ├── core_test.exs
        └── gitlab_test.exs
```

**Structure Decision**: Extend the existing Elixir service in place. Keep GitLab-specific API and webhook behavior under `SymphonyElixir.GitLab`, keep HTTP routing under `SymphonyElixirWeb`, and keep shared orchestration behavior in `SymphonyElixir.Orchestrator`.

## Complexity Tracking

No constitution violations are currently required. Stage 3 adds a local file-backed state store instead of a database because the current service has no database dependency and the requested hardening is scoped to longer-running staging plus future production preparation. This is intentionally a single-node design; shared multi-replica state remains an operational risk until a database or external durable store is introduced.

## Stage 3 Operational Hardening Plan

Baseline:

- Stage 2 live staging validation completed against a disposable GitLab project.
- Success path reached `soc::human-review`.
- Failure path reached `soc::failed`.
- Duplicate `/soc run` did not produce a duplicate completion.
- GitLab token and webhook secret were not visible to the local Codex process.

Required hardening:

1. Replace process-only webhook idempotency with persistent delivery records.
2. Persist lifecycle writeback completion records for acknowledgement, transition, completion, and failure operations.
3. Persist audit records for handled, duplicate, ignored, and failed webhook deliveries.
4. Add bounded retry/backoff for GitLab API writeback operations.
5. Add restart-safe tests for webhook replay and lifecycle comment suppression.
6. Add writeback retry tests for retryable failures and exhausted failures.
7. Update documentation for production-readiness operations.

Persistent State Design:

- Default path: a deterministic file under `workspace.root` when `tracker.state_path` is not configured.
- Configurable path: `tracker.state_path`, recommended for production so state survives workspace cleanup and host restarts.
- Format: JSON document with `schema_version`, `webhook_events`, `writebacks`, and `issue_runs`.
- Contents: event keys, operation keys, issue IIDs, lifecycle names, statuses, attempt counts, timestamps, and sanitized reasons.
- Exclusions: no GitLab API tokens, webhook secrets, issue bodies, comments, agent output, or SOC data.
- Atomicity: write through a temporary file and rename into place.
- Concurrency: state mutations are serialized by a GenServer in this single-node implementation.

Writeback Retry Design:

- Applies to GitLab issue notes and label updates.
- Retries transport errors, HTTP 429, and HTTP 5xx responses.
- Does not retry expected permission or validation failures such as HTTP 400, 401, 403, or 404.
- Uses bounded exponential backoff controlled by `tracker.writeback_max_attempts` and `tracker.writeback_base_backoff_ms`.
- Records exhausted writeback failures in persistent state for audit and operator recovery.

Out of scope for Stage 3:

- Cortex integration.
- IOC enrichment.
- Responder actions.
- SOC UI.
- Branch creation.
- Merge request creation.
- Multi-node shared state.

## Stage 3.5 Repository Hygiene and Real Runner Validation Plan

Baseline:

- Stage 3 persistent idempotency, audit storage, and bounded writeback retry are
  implemented and validated with automated tests and fake-runner staging
  checks.
- The local environment has an authenticated `codex app-server` executable.

Required validation:

1. Track `.specify/` and `.agents/` because they are required to reproduce the
   Spec Kit workflow used by this feature.
2. Exclude local historical prompts, reference-only workspace notes,
   unreviewed devcontainer experiments, runtime state, secrets, and staging
   evidence from version control.
3. Add a staging helper mode that wraps and executes the real local
   `codex app-server` while recording only whether GitLab secret variables are
   absent.
4. Run the success path with the real runner, then re-run duplicate command,
   persistent replay suppression after restart, and failure lifecycle checks.
5. Re-run formatting, full tests, specs check, diff check, clean-room checks,
   and sanitized staging evidence assertions.

The deterministic real-runner failure check invokes the real Codex executable
with an invalid CLI option. This validates orchestrator startup-failure mapping
to `soc::failed`; it is not evidence of a failed model turn.

Observed real-runner gap:

- A real agent turn lasts long enough for orchestrator reconciliation to run
  while the issue carries `soc::running`.
- GitLab issue normalization previously recognized only configured polling
  states and configured terminal states. With `active_states: ["soc::queued"]`,
  refresh normalized `soc::running` back to GitLab `opened`, then stopped the
  active agent as non-active.
- The fix preserves all known GitLab lifecycle labels during normalization and
  treats `soc::claimed`, `soc::running`, and `soc::waiting-input` as controlled
  active lifecycle states during GitLab reconciliation. Polling discovery
  remains limited to configured candidate labels such as `soc::queued`.

## Phase 0: Research Output

See [research.md](research.md).

## Phase 1: Design Output

See [data-model.md](data-model.md), [contracts/gitlab-webhook.md](contracts/gitlab-webhook.md), and [quickstart.md](quickstart.md).

## Post-Design Constitution Check

- Official Repository Authority: Pass. The design does not require external code adoption.
- Adapter-Owned Tracker Mutation: Pass. Contracts state that all GitLab mutation is adapter-owned.
- Spec-Driven Lifecycle Changes: Pass. Implementation tasks are derived from this plan and spec.
- Testable Control Plane: Pass after planned tests are implemented.
- Narrow Scope and Future SOC Boundary: Pass. Future SOC features remain excluded.

## Final Stabilization Results

Status: Complete for the scoped GitLab control-plane phase.

Resolved gaps:

1. Completion and failure lifecycle comments are now adapter-owned and covered by lifecycle tests.
2. GitLab lifecycle tests cover queued issue dispatch, `soc::running`, normal completion to `soc::human-review`, failure to `soc::failed`, and comment writeback.
3. Duplicate `/soc run` behavior is covered for duplicate webhook delivery and active label states.
4. Label transition safety is covered for conflicting lifecycle label removal while preserving unrelated labels.
5. The `core_test.exs:1003` workspace hook shell compatibility blocker was fixed by selecting Bash for local shell hooks when available, with `sh` as fallback.
6. Documentation now covers GitLab token scopes, webhook setup, label setup, sample workflow, known limitations, and future phases.
7. Clean-room verification was re-run against implementation, tests, README, and feature specs.

Validation commands:

```text
mix test test/symphony_elixir/gitlab_test.exs test/symphony_elixir/gitlab_lifecycle_test.exs
mix test test/symphony_elixir/app_server_test.exs test/symphony_elixir/gitlab_test.exs test/symphony_elixir/gitlab_lifecycle_test.exs
mix test test/symphony_elixir/core_test.exs:1003 test/symphony_elixir/core_test.exs:1087 test/symphony_elixir/core_test.exs:1245 test/symphony_elixir/core_test.exs:1376
mix test
mix format --check-formatted
mix specs.check
git diff --check
rg -n "/workspaces/reference|Dripmaster|symphony-py" elixir/lib elixir/test elixir/README.md specs/001-gitlab-control-plane --glob '!tasks.md' --glob '!plan.md'
make all
```

Final result: all validation commands passed. `make all` passed with 251 tests, 0 failures, 2 skipped, 100% reported coverage for the enforced coverage set, and 0 Dialyzer errors.
