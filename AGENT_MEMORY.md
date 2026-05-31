# Agent Memory: Symphony GitLab Control Plane

## Current Project Purpose

This project extends the official OpenAI Symphony codebase with GitLab
control-plane support. GitLab currently serves as the issue tracker, command
surface, lifecycle-state source, and adapter-controlled writeback target.

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

## Current Verified Capabilities

- `/soc run` through a GitLab issue Note Hook.
- Webhook secret validation and line-start command parsing.
- Queue, claim, orchestrator dispatch, and lifecycle reconciliation.
- Adapter-owned GitLab issue label transitions and issue-note writeback.
- Normal completion to `soc::human-review`.
- Failure mapping to `soc::failed`.
- Duplicate `/soc run` suppression.
- Restart-safe webhook replay suppression using local file-backed state.
- Persistent suppression of duplicate lifecycle comments and transitions.
- Bounded retry and audited exhaustion for GitLab writeback operations.
- Local real Codex app-server validation.
- Local Codex agent processes do not receive `GITLAB_API_TOKEN` or
  `GITLAB_WEBHOOK_SECRET`.

## Important Implementation Boundaries

- GitLab write credentials belong only to the GitLab adapter and client layer.
- Codex agents must not receive GitLab write tokens or webhook secrets.
- Codex may produce outputs and artifacts, but GitLab mutation must remain
  adapter-controlled.
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
- Branch creation, commit automation, push, merge request creation, and CI
  workflow handling are not implemented yet.
- Cortex integration, IOC enrichment, responder actions, SOC UI, endpoint
  isolation, automatic blocking, and other production-impacting actions are
  not implemented.

## Current Validation Status

The most recent Stage 3.5 work passed the full Elixir validation path,
including formatting, the full test suite, specs checks, Credo, enforced
coverage, Dialyzer, diff checks, clean-room searches, and sanitized live
staging assertions. See
[`specs/001-gitlab-control-plane/live-staging-validation.md`](specs/001-gitlab-control-plane/live-staging-validation.md)
for staging-validated behavior and limitations.

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

Stage 4 should define and stage-validate the branch, commit, merge request, and
CI workflow. Start with a Spec Kit specification update before implementation.

Stage 4 must preserve adapter-owned GitLab mutation. Codex may generate patch
or artifact content, but adapter-controlled code should perform branch
creation, commit, push, and merge request creation. Credential-bearing GitLab
operations must not move into the Codex agent process.

## Explicit Non-Goals Until Stage 4 Is Complete

- No Cortex integration.
- No IOC enrichment.
- No responder actions.
- No SOC UI.
- No automatic blocking or endpoint isolation.
- No production GitLab project integration.
- No multi-node production deployment.

## Recommended Stage 4 Preflight Questions

1. What GitLab token scopes are required for branch and merge request
   operations?
2. Can branch and merge request creation remain entirely adapter-controlled
   without exposing write tokens to Codex?
3. How should CI failures update issue labels, issue comments, and merge
   request state?
4. How should duplicate branch and merge request creation be suppressed across
   retries and process restarts?
5. Which patch, artifact, commit-message, and metadata outputs may Codex
   generate?
6. What rollback or recovery behavior is required if branch creation, commit,
   push, or merge request creation fails partway through?
