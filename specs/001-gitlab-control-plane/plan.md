# Implementation Plan: GitLab Control Plane Stabilization

**Branch**: `001-gitlab-control-plane` | **Date**: 2026-05-29 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/001-gitlab-control-plane/spec.md`

## Summary

Stabilize the GitLab control-plane foundation so a GitLab issue comment can request `/soc run`, the adapter validates and queues the issue, the orchestrator discovers and dispatches it, lifecycle labels and comments are written only by the adapter, and normal completion, failure, and duplicate delivery behavior are covered by tests and documentation.

The current implementation already includes initial GitLab tracker routing, a REST client, webhook controller, command parser, adapter writeback, and partial lifecycle label updates. The stabilization phase must close the documented gaps before expanding scope.

## Technical Context

**Language/Version**: Elixir 1.19.x on OTP 28, as configured by `elixir/mise.toml`

**Primary Dependencies**: Phoenix/Bandit for the optional HTTP server, Req for outbound HTTP, Ecto changesets for config validation, ExUnit for tests

**Storage**: In-memory orchestrator state and in-memory webhook idempotency for this phase; no database

**Testing**: ExUnit targeted tests plus relevant full-suite validation under `elixir/`

**Target Platform**: Long-running Symphony Elixir service in trusted evaluation environments

**Project Type**: Elixir service with optional HTTP API and dashboard

**Performance Goals**: Webhook processing should be bounded by local validation plus GitLab API writeback latency; polling should avoid unbounded duplicate issue dispatch

**Constraints**: GitLab mutation stays in adapter layer; Codex agent does not receive GitLab write tokens; reference-only repository code must not be copied; no Cortex, responder actions, IOC enrichment, SOC UI, endpoint isolation, automatic blocking, branch creation, or merge request creation

**Scale/Scope**: Single configured GitLab project for this phase, project issue IIDs as tracker IDs, process-local idempotency only

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

No constitution violations are currently required. The in-memory idempotency limitation is accepted for this phase and documented as a known limitation rather than a production hardening claim.

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
