# Agent Memory: Symphony GitLab Control Plane

## Current Project Purpose

This project extends the official OpenAI Symphony codebase with a reusable
GitLab-backed agent orchestration layer. GitLab currently serves as the issue
tracker, operator command surface, lifecycle-state source, and
adapter-controlled writeback target.

The current architecture is:

```text
GitLab issue or comment
-> GitLab adapter
-> Symphony orchestrator
-> isolated workspace
-> Codex agent
-> adapter-controlled GitLab writeback
```

## Current Completed Stages

- **Stage 1: GitLab control-plane foundation.** Added GitLab issue reading,
  label-derived lifecycle state, comment command parsing, webhook handling,
  adapter-owned comments, adapter-owned label transitions, and basic run
  lifecycle mapping.
- **Stage 2: Live GitLab staging validation.** Validated success, failure,
  duplicate command, webhook setup, and local credential-boundary behavior
  against a disposable staging project.
- **Stage 3: Operational hardening and persistent idempotency.** Added
  single-node file-backed state, restart-safe webhook replay suppression,
  lifecycle writeback idempotency, sanitized audit records, and bounded GitLab
  API writeback retry with backoff.
- **Stage 3.5: Repository hygiene and real local Codex runner validation.**
  Tracked reproducible Spec Kit assets, excluded local-only files, validated a
  real local Codex app-server, and fixed long-running GitLab lifecycle
  reconciliation.
- **Stage 4: GitLab merge request workflow milestone.** Added adapter-owned
  dry-run planning, staging-gated live branch/commit/MR creation, idempotent
  MR-link writeback, CI reconciliation, disposable CI success/failure staging
  validation, and restart-safe recovery for partial remote success.
- **Stage 4.5: Run timeline and audit observability.** Added structured audit
  events, trace and run correlation, append-only local audit logs, structured
  logger metadata, and a local timeline query path for GitLab runs.

## Current Verified Capabilities

- `/agent run` through a GitLab issue Note Hook.
- `/soc run` retained as a backward-compatible alias.
- Webhook secret validation and line-start command parsing.
- Queue, claim, orchestrator dispatch, and lifecycle reconciliation.
- Adapter-owned GitLab issue label transitions and issue-note writeback.
- Normal completion to `soc::human-review`.
- Failure mapping to `soc::failed`.
- Duplicate `/agent run` and `/soc run` suppression.
- Restart-safe webhook replay suppression using local file-backed state.
- Persistent suppression of duplicate lifecycle comments and transitions.
- Bounded retry and audited exhaustion for GitLab writeback operations.
- Local real Codex app-server validation.
- Local Codex agent processes do not receive `GITLAB_API_TOKEN` or
  `GITLAB_WEBHOOK_SECRET`.
- Stage 4.2 live staging MR creation with adapter-owned branch, commit, merge
  request, MR-link writeback, and duplicate suppression.
- Stage 4.3 CI reconciliation MVP with newest-pipeline selection, normalized CI
  status classes, state persistence, idempotent issue writeback, and human
  review preservation.
- Stage 4.3.1 disposable CI validation with real staging success and failure
  pipelines, idempotent CI comments, open-MR preservation, and preserved token
  boundaries.
- Stage 4.4 restart hardening for remote branch, commit, MR, and MR-link
  partial-failure recovery with deterministic provenance checks and mismatch
  blocking.
- Stage 4.5 append-only audit events with trace correlation for webhook
  handling, run lifecycle, MR mutation, CI reconciliation, duplicate
  suppression, and recovery paths.
- Stage 4.5.1 observability polish with structured Logger metadata, a
  production-facing audit read API, serialized local audit appends, and
  stronger redaction coverage.

## Important Implementation Boundaries

- GitLab write credentials belong only to the GitLab adapter and client layer.
- Codex agents must not receive GitLab write tokens or webhook secrets.
- Codex may produce outputs and artifacts, but GitLab mutation must remain
  adapter-controlled.
- Generic agent orchestration belongs in this repository. Security-specific
  Cortex, IOC, or SOC workflows should remain in a separate upper-layer
  application or repository.
- All implementation must remain clean-room work based on the official
  Symphony repository, official specifications, official GitLab documentation,
  and project-owned design artifacts.
- Reference-only repository code, tests, documentation, comments, internal
  names, and file structure must not be copied or mechanically translated.
- Specification updates must precede new lifecycle or writeback behavior.

## Current Known Limitations

- Persistent state is local file-backed state intended for one Symphony
  deployment. Multi-node deployment requires shared or centralized state.
- The implementation is staging validated and is not yet production-ready.
- Temporary tunnels are staging-only and are not suitable production
  endpoints.
- The remote-worker token boundary has not yet been validated with a real
  runner.
- The live failure path currently proves runner startup failure mapping more
  directly than full model-turn failure behavior.
- Stage 4 remains staging-validated only. CI reconciliation is polling-based,
  and Stage 4.4 restart-hardening remains single-node because persistent state
  is still local file-backed state rather than a shared store.
- Audit observability remains local-only. The timeline query reads from the
  local JSONL audit log and is not a centralized or multi-node audit system.
- Cortex integration, IOC enrichment, responder actions, SOC UI, endpoint
  isolation, automatic blocking, and other production-impacting actions are
  not implemented.

## Current Validation Status

The completed GitLab integration milestone passed the full Elixir validation
path, including formatting, targeted GitLab tests, the full test suite, specs
checks, diff checks, clean-room searches, and sanitized live staging
assertions. See
[`specs/001-gitlab-control-plane/live-staging-validation.md`](specs/001-gitlab-control-plane/live-staging-validation.md)
and
[`specs/002-gitlab-mr-workflow/milestone-closure.md`](specs/002-gitlab-mr-workflow/milestone-closure.md)
for staging evidence, milestone scope, and remaining non-production limits.

## Files and Areas Future Agents Should Read First

1. [`.specify/feature.json`](.specify/feature.json)
2. [`.specify/memory/constitution.md`](.specify/memory/constitution.md)
3. [`specs/001-gitlab-control-plane/`](specs/001-gitlab-control-plane/)
4. [`elixir/lib/symphony_elixir/gitlab/`](elixir/lib/symphony_elixir/gitlab/)
5. [`elixir/lib/symphony_elixir/orchestrator.ex`](elixir/lib/symphony_elixir/orchestrator.ex)
6. [`elixir/lib/symphony_elixir_web/controllers/gitlab_webhook_controller.ex`](elixir/lib/symphony_elixir_web/controllers/gitlab_webhook_controller.ex)
7. [`elixir/test/symphony_elixir/gitlab_test.exs`](elixir/test/symphony_elixir/gitlab_test.exs)
8. [`elixir/test/symphony_elixir/gitlab_lifecycle_test.exs`](elixir/test/symphony_elixir/gitlab_lifecycle_test.exs)
9. [`specs/001-gitlab-control-plane/live-staging-validation.md`](specs/001-gitlab-control-plane/live-staging-validation.md)

## Next Recommended Stage

The GitLab integration milestone is complete for staging-only scope. The
preferred operator command is now `/agent run`, with `/soc run` retained only
as a compatibility alias. Any future work should begin from explicit
production-readiness requirements rather than expanding Stage 4 behavior
implicitly.

Adapter-owned GitLab mutation remains mandatory. Codex may generate patch or
artifact content, but adapter-controlled code must keep branch, commit, merge
request, and CI writeback operations outside the Codex agent process.

## Explicit Non-Goals After Milestone Closure

- No Cortex integration.
- No IOC enrichment.
- No responder actions.
- No SOC UI.
- No automatic blocking or endpoint isolation.
- No production GitLab project integration.
- No multi-node production deployment.

## Recommended Post-Milestone Questions

1. Should CI reconciliation remain polling-based, or is a webhook-assisted path
   required before any broader rollout?
2. What shared state design is required before any multi-node or
   production-like deployment?
3. What additional remote-worker token-boundary validation is required before
   trusting non-local runners?
