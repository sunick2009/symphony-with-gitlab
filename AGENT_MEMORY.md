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
- **Stage 003: Docker single-machine deployment** (`specs/003-docker-deployment`).
  Multi-stage Dockerfile (builder + runtime on the same `hexpm/elixir` image so
  ERTS matches the escript), plus an optional `codex.health_check_command`
  pre-flight that detects Codex auth failures before an agent run starts.
- **Stage 004: Per-turn hooks and multi-phase workflow**
  (`specs/004-per-turn-hooks`). Added `before_turn`/`after_turn` workspace hooks
  that fire around every Codex turn (not just once per run), enabling a
  plan-first-then-execute workflow where the plan and each phase's progress sync
  to GitLab between turns instead of only at run end. Validated end-to-end
  against real Codex on live staging.

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
- Stage 004 per-turn workspace hooks (`before_turn`/`after_turn`) invoked around
  each Codex turn in `agent_runner.ex` `do_run_codex_turns/9`, with full ordering
  `before_run → (before_turn → turn → after_turn) × N → after_run`. Per-turn hooks
  are non-fatal and backward-compatible (unset = no-op).
- Stage 004 multi-phase GitLab workflow (`elixir/WORKFLOW.gitlab.md`): planning
  mode writes `output/workpad.md`; execution mode runs one phase per turn with
  evidence enforced in `output/evidence/phase-N.md`; a single workpad comment is
  PUT-updated in the issue each turn; completion (`output/.state/completed`) moves
  the issue to `soc::human-review`. Validated e2e with real Codex (issues #32/#33):
  plan appears before execution, phases update progressively, run stops cleanly.

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

## Multi-Phase Workflow Gotchas (learned from Stage 004 e2e)

These are non-obvious requirements for the per-turn multi-phase workflow. Future
agents editing `WORKFLOW.gitlab.md` or the turn loop must preserve them:

- **`active_states` must include `soc::running`.** The agent works while the issue
  is `soc::running`; if it is absent from `active_states`, the per-turn continuation
  check stops the loop after the planning turn and no phases execute. The poller's
  claim/running guards prevent re-dispatch, so including it is safe.
- **Evidence-validation regex must anchor to the checklist bullet**
  (`(?m)^\s*-\s*\[x\]\s*[Pp]hase\s*(\d+)`). A loose `[x].*?phase(\d+)` matches prose
  that mentions both tokens and falsely flags unchecked phases as complete.
- **Completion stop**: `after_turn` moves the issue to `soc::human-review` when
  `output/.state/completed` exists; otherwise the loop runs to `max_turns` and burns
  empty turns (real Codex cost).
- **Prompt files must not be split with `~r/\R/`.** `Workflow.split_front_matter`
  uses `~r/\r\n|\r|\n/`; `\R` matches the NEL byte 0x85 mid-character in multibyte
  UTF-8 (e.g. 先 = E5 85 88), corrupting non-ASCII prompts and crashing
  `Jason.encode!` at codex turn start.
- The agent process has no GitLab token, so it cannot move labels itself; all GitLab
  mutation (workpad comment, label transitions) happens in the `after_turn` hook,
  which runs with adapter credentials.

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

Stage 004 (per-turn hooks + multi-phase workflow) passed the full Elixir test
suite (315 tests, 0 failures, 2 Docker-only skips) and was validated end-to-end
against real Codex on live staging: the plan posts to GitLab after the planning
turn (before execution), each phase progressively updates the same workpad
comment via PUT, evidence is enforced, and the run stops cleanly at
`soc::human-review` without re-dispatch. Three integration gaps and one UTF-8
prompt-corruption bug were found and fixed during that run; see the
"Multi-Phase Workflow Gotchas" section and `specs/004-per-turn-hooks/spec.md`.

The earlier GitLab integration milestone passed the full Elixir validation
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
10. [`AGENTS.md`](AGENTS.md) — multi-phase workflow model and hook timing
11. [`specs/004-per-turn-hooks/spec.md`](specs/004-per-turn-hooks/spec.md) — per-turn hooks + e2e findings
12. [`elixir/WORKFLOW.gitlab.md`](elixir/WORKFLOW.gitlab.md) — canonical multi-phase workflow template
13. [`elixir/lib/symphony_elixir/agent_runner.ex`](elixir/lib/symphony_elixir/agent_runner.ex) — per-turn hook invocation
14. [`elixir/lib/symphony_elixir/workspace.ex`](elixir/lib/symphony_elixir/workspace.ex) — hook runners

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
