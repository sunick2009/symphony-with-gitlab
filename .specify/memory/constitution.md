# Symphony GitLab Integration Constitution

## Core Principles

### I. Official Repository Authority

All implementation work must target the official OpenAI Symphony-based repository in this workspace. Reference repositories may be read only for high-level conceptual analysis and must not provide copied files, code, tests, comments, documentation sections, internal names, or mechanically translated structures.

### II. Adapter-Owned Tracker Mutation

Issue tracker mutation must remain inside the tracker adapter layer. Codex agent turns may receive issue context and operate inside isolated workspaces, but they must not receive GitLab write tokens or directly mutate GitLab issue labels, comments, merge requests, or other tracker state.

### III. Spec-Driven Lifecycle Changes

GitLab lifecycle behavior must be specified before implementation changes. Any implementation gap discovered after planning must be documented in the plan or tasks before code changes are made.

### IV. Testable Control Plane

Control-plane behavior must be covered by focused automated tests. Webhook validation, command parsing, polling discovery, label state derivation, label transitions, comment writeback, failure handling, duplicate delivery behavior, and token boundaries require tests before this phase is considered complete.

### V. Narrow Scope and Future SOC Boundary

This phase is limited to the GitLab control plane. Cortex integration, IOC enrichment, responder actions, SOC UI, automatic blocking, endpoint isolation, branch creation, and merge request creation are future features and must not be included in this stabilization phase.

## Additional Constraints

The Elixir implementation must preserve existing workspace isolation, retry, reconciliation, and cleanup semantics. Public functions in `elixir/lib/` require `@spec` annotations unless exempted by the repository's existing rules. Documentation must be updated whenever behavior or configuration changes.

## Development Workflow

Use Spec Kit artifacts in `specs/` as the source of truth for this phase. Keep tasks separated into stabilization work and future work. Validate with targeted tests first, then the relevant full test suite. If a remaining full-suite failure is unrelated, document the failure, root cause, and upstream-safe fix rather than silently excluding it.

## Governance

This constitution supersedes conflicting historical prompts for the GitLab control-plane stabilization phase. Amendments require updating this file and any affected spec, plan, or task artifacts in the same change.

**Version**: 1.0.0 | **Ratified**: 2026-05-29 | **Last Amended**: 2026-05-29
