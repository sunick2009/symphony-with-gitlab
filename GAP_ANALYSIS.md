# Gap Analysis: OpenAI Symphony -> GitLab Integration

## 1. Current OpenAI Symphony Architecture

The official OpenAI Symphony repository contains a language-agnostic specification and an Elixir reference implementation under `elixir/`. The Elixir service loads `WORKFLOW.md`, validates typed runtime settings, polls a tracker, creates isolated per-issue workspaces, and runs Codex through app-server mode. The orchestrator owns polling, dispatch eligibility, retry state, active run reconciliation, blocked run tracking, and workspace cleanup for terminal issues.

## 2. Existing Issue Tracker Abstraction

`SymphonyElixir.Tracker` is already a useful adapter boundary. It supports candidate issue reads, state refresh by issue IDs, terminal-state issue reads, comment creation, and state updates. The memory adapter implements this contract for tests. The abstraction is currently sufficient for a GitLab control-plane foundation, although the domain record is still named `SymphonyElixir.Linear.Issue`.

## 3. Linear-Coupled Components

Several components assume Linear in naming or behavior:

- `SymphonyElixir.Linear.Client`, `SymphonyElixir.Linear.Adapter`, and `SymphonyElixir.Linear.Issue` are the only production tracker implementation.
- `Config.validate!/0` only permits `linear` and `memory`.
- Missing-token and missing-project errors are Linear-specific.
- The orchestrator and agent runner log messages mention Linear in several places.
- The default tracker endpoint points to Linear GraphQL.
- The specification still describes Linear as the tracker for the current version.

## 4. Required GitLab Adapter Components

The GitLab foundation needs the following independently implemented components:

- A GitLab REST client for project issue reads, issue note creation, and label mutation.
- A tracker adapter selected by `tracker.kind: gitlab`.
- Label-based state detection that treats GitLab issue labels as workflow states.
- A command parser for issue comment commands such as `/soc run`, `/soc status`, `/soc retry`, and `/soc cancel`.
- A webhook endpoint that validates `X-Gitlab-Token`, handles Issue Hook and Note Hook payloads, and ignores unsupported events.
- Adapter-controlled writeback for comments and label transitions.
- Basic idempotency for duplicate webhook deliveries.
- Tests for parsing, webhook handling, label mutation payloads, and config routing.

## 5. Reference-Only Observations from Dripmaster/symphony-py

The reference repository was cloned only to `/workspaces/reference/symphony-py-readonly` and marked read-only. It appears to validate that GitLab issue polling and label-based workflow states are feasible. It also suggests several operational considerations: GitLab label filtering has practical implications for polling strategy, project issue identifiers are important for REST calls, terminal labels should take priority over active labels, and polling systems need deduplication when multiple active labels are queried.

No files, functions, classes, tests, comments, documentation sections, internal names, or implementation snippets from the reference repository are copied or ported into the working repository.

## 6. Clean-Room Implementation Plan

Implement GitLab support from the official Symphony codebase, official Symphony specification, official GitLab REST/webhook documentation, and local architecture requirements. Use the existing Elixir tracker behavior as the integration boundary. Keep GitLab API mutation inside the adapter layer so Codex runs do not need GitLab write tokens. Use GitLab issue labels as state names and expose a webhook endpoint for command-driven state transitions. Do not implement Cortex, responder actions, IOC enrichment, endpoint isolation, branch creation, or merge request creation in this milestone.

## 7. Files to Modify

- `elixir/lib/symphony_elixir/tracker.ex`
- `elixir/lib/symphony_elixir/config/schema.ex`
- `elixir/lib/symphony_elixir/config.ex`
- `elixir/lib/symphony_elixir_web/router.ex`
- `elixir/test/support/test_support.exs`
- Existing tests that assert tracker-kind validation or current workflow defaults.

## 8. Files to Add

- `REFERENCE_REVIEW.md`
- `elixir/lib/symphony_elixir/gitlab/client.ex`
- `elixir/lib/symphony_elixir/gitlab/adapter.ex`
- `elixir/lib/symphony_elixir/gitlab/command.ex`
- `elixir/lib/symphony_elixir/gitlab/webhook.ex`
- `elixir/lib/symphony_elixir_web/controllers/gitlab_webhook_controller.ex`
- Focused tests for the new GitLab modules and webhook route.

## 9. Risks and Open Questions

- GitLab REST APIs use project issue IIDs for issue notes and issue updates. The current generic issue struct has no separate `iid` field, so the initial implementation should use the GitLab issue IID as the tracker issue ID for project-scoped operation.
- GitLab label names can differ in case. Internal comparisons should normalize case, while API requests should preserve configured label names.
- Webhook idempotency without a database is process-local and will not survive restarts. This is acceptable for the initial control-plane foundation but should be revisited before production use.
- The orchestrator dispatch lifecycle currently does not call tracker writebacks when runs start or finish. Adapter-controlled lifecycle transitions beyond webhook command handling may require orchestrator hooks in a later patch.
- The requested `symphony_gitlab_integration_design.md` and `codex_prompt_for_symphony_gitlab_integration.md` files are not present in the working tree, so this plan uses the current user request as the controlling architecture document.
