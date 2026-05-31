# Implementation Plan: GitLab Merge Request Workflow

**Branch**: `002-gitlab-mr-workflow` | **Date**: 2026-05-31 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/002-gitlab-mr-workflow/spec.md`

## Summary

Extend the completed GitLab control plane with a staging-only Stage 4 workflow where a successful `/soc run` produces adapter-owned repository mutation: collect approved workspace outputs, create or reuse a deterministic source branch, create a batch commit through the GitLab API, open or reuse a merge request, reflect CI status back to the issue, and preserve the existing token boundary and persistent single-node idempotency guarantees.

The core design choice is to keep GitLab repository mutation inside the adapter layer and prefer GitLab API based branch or commit creation over credentialed local `git push`. This reduces credential spread and keeps the existing adapter-owned mutation model coherent, at the cost of narrower repository write semantics and request-size constraints.

## Technical Context

**Language/Version**: Elixir 1.19.x on OTP 28, as configured by `elixir/mise.toml`

**Primary Dependencies**: Phoenix/Bandit for optional HTTP endpoints, Req for GitLab API access, ExUnit for tests, existing Symphony orchestrator and agent-runner stack

**Storage**: Existing file-backed GitLab state store extended with repository mutation and CI observation records; no new database in Stage 4

**Testing**: Focused ExUnit adapter and lifecycle tests plus a staging-only validation script sequence for disposable GitLab projects

**Target Platform**: Long-running Symphony Elixir service in trusted evaluation environments with access to a disposable GitLab staging project

**Project Type**: Elixir service with GitLab-backed control-plane and adapter-owned repository mutation

**Performance Goals**: Repository finalization should remain bounded by GitLab API latency and configured retry limits; CI reconciliation should converge without duplicate writeback

**Constraints**: Adapter owns GitLab write credentials; Codex agent must not receive GitLab write tokens or webhook secrets; no production project integration; no Cortex, IOC enrichment, responder actions, SOC UI, auto-merge, auto-blocking, endpoint isolation, or agent-owned `git push`

**Scale/Scope**: Single staging GitLab project, one issue-to-MR workflow per run, persistent idempotency for one Symphony deployment

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- Official Repository Authority: Pass. Work remains in the official Symphony repository in this workspace.
- Adapter-Owned Tracker Mutation: Pass with extension. Stage 4 expands adapter-owned mutation from issue comments and labels to repository branch, commit, merge request, and issue writeback operations.
- Spec-Driven Lifecycle Changes: Pass. Stage 4 behavior is specified before implementation.
- Testable Control Plane: Pass with required task follow-up. Stage 4 adds repository mutation and CI reconciliation tests.
- Narrow Scope and Future SOC Boundary: Pass. Stage 4 remains limited to staging-safe GitLab repository workflow and excludes broader SOC automation.

## Project Structure

### Documentation (this feature)

```text
specs/002-gitlab-mr-workflow/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── gitlab-stage4-lifecycle.md
├── checklists/
│   └── requirements.md
└── tasks.md
```

### Source Code

```text
elixir/
├── lib/symphony_elixir/
│   ├── gitlab/
│   │   ├── adapter.ex
│   │   ├── client.ex
│   │   ├── state_store.ex
│   │   ├── webhook.ex
│   │   └── mr_workflow.ex
│   ├── orchestrator.ex
│   ├── tracker.ex
│   └── workspace.ex
├── test/symphony_elixir/
│   ├── gitlab_test.exs
│   ├── gitlab_lifecycle_test.exs
│   └── gitlab_mr_workflow_test.exs
└── README.md
```

**Structure Decision**: Keep Stage 4 inside the existing GitLab adapter boundary. Add a narrowly scoped GitLab MR workflow module rather than spreading repository mutation logic across the webhook and orchestrator directly. Extend the current client and state store rather than introducing a new service boundary.

## Complexity Tracking

No constitution violations are currently required. Stage 4 increases adapter responsibility, but that increase is the simplest way to preserve the established token boundary and idempotent mutation model.

## Phase 0: Research Output

See [research.md](research.md).

## Phase 1: Design Output

See [data-model.md](data-model.md), [contracts/gitlab-stage4-lifecycle.md](contracts/gitlab-stage4-lifecycle.md), and [quickstart.md](quickstart.md).

## Post-Design Constitution Check

- Official Repository Authority: Pass. No external implementation code is required.
- Adapter-Owned Tracker Mutation: Pass. Branch, commit, merge request, and issue-note mutation remain adapter-owned.
- Spec-Driven Lifecycle Changes: Pass. Lifecycle and CI mapping are documented before implementation.
- Testable Control Plane: Pass after planned tests are implemented.
- Narrow Scope and Future SOC Boundary: Pass. Stage 4 remains staging-only and excludes production-impacting automation.

## Stage 4 Design Decisions

1. **Repository mutation path**  
   Choose GitLab Branches API plus Commits API batch actions as the default Stage 4 mutation path. This keeps mutation behind the existing `api` scope and avoids provisioning `write_repository` or a credentialed local remote for `git push`.

2. **Branch naming**  
   Use a deterministic branch pattern such as `soc/issue-<iid>/<run-fingerprint>` where `<run-fingerprint>` is derived from a stable digest of the approved artifact set or patch manifest. This makes retries and duplicate suppression inspectable.

3. **Duplicate suppression**  
   Persist operation keys for branch, commit, MR creation, MR-link writeback, and CI status writeback. On re-entry, look up existing branch and MR state before any new mutation.

4. **Output collection**  
   Define an adapter-owned artifact collector that reads only approved files from the isolated workspace, normalizes them into commit actions, rejects out-of-repo paths, and records a manifest digest used for provenance.

5. **CI reconciliation**  
   Poll or refresh the merge request’s newest relevant pipeline status and write one idempotent issue note per status class: created or pending, success, failure.

6. **Staging validation boundary**  
   Stage 4 live validation must run only against a disposable staging project with explicit operator acknowledgement and must never target production GitLab projects.

## Sanitized Staging Evidence

- **Stage 4.2 live MR creation** was validated on 2026-05-31 against the
  disposable staging project using issue `#19`, source branch
  `soc/issue-19/fdabb4c741ea`, commit `eee92b65`, and merge request `!1`.
- Duplicate `/soc run` on the same issue did not create a second branch,
  commit, merge request, or MR link comment. The adapter instead wrote one
  explanatory comment that the issue was already in a Symphony lifecycle state.
- **Stage 4.3 CI reconciliation** remains staging-limited by the current
  disposable project's lack of CI configuration. The live validation path can
  therefore prove repository mutation, MR-link writeback, duplicate
  suppression, and token-boundary preservation, but only the no-pipeline CI
  observation path until a pipeline exists.
- **Stage 4.3.1 disposable CI validation** succeeded on 2026-05-31 after
  adding a staging-only `.gitlab-ci.yml` artifact through the existing
  adapter-owned MR workflow. The success sample used issue `#23`, MR `!2`,
  branch `soc/issue-23/1ac473b8b3cd`, pipeline `#44`, and exactly one CI
  success comment. The failure sample used issue `#24`, MR `!3`, branch
  `soc/issue-24/eddfd104b71d`, pipeline `#45`, and exactly one CI failure
  comment. In both cases the issue remained `soc::human-review`, the MR
  remained open, duplicate reconciliation preserved a single CI comment, and
  the local token boundary remained intact.
