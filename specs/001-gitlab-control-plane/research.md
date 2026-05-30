# Research: GitLab Control Plane Stabilization

## Decision: Use existing tracker behavior as the GitLab adapter boundary

**Rationale**: Symphony already routes tracker reads and writes through `SymphonyElixir.Tracker`. Reusing this boundary preserves orchestrator shape and keeps GitLab mutation out of Codex.

**Alternatives considered**: A separate GitLab bot process or a Codex tool with GitLab token access. Both increase token exposure and complicate lifecycle ownership.

## Decision: Use GitLab project issue IID as the tracker issue ID for this phase

**Rationale**: GitLab issue comments and label updates operate naturally on project issue IIDs. The current normalized issue model has one `id` field, so using the IID avoids adding a broader domain-model refactor during stabilization.

**Alternatives considered**: Store both global issue ID and IID in the normalized issue struct. This may be preferable later, but it expands blast radius.

## Decision: Keep webhook idempotency in memory for this phase

**Rationale**: The current Symphony implementation avoids a persistent database. Process-local idempotency is sufficient to prove duplicate webhook handling in tests and documents the restart limitation.

**Alternatives considered**: ETS with TTL cleanup, file-backed state, or database-backed delivery records. Persistent idempotency is a future hardening item.

## Decision: Treat lifecycle labels as mutually exclusive within the configured GitLab/SOC lifecycle set

**Rationale**: A single workflow state is easier to reason about for dispatch, retry, and handoff. Adding the target lifecycle label while removing conflicting lifecycle labels avoids ambiguous states.

**Alternatives considered**: Allow multiple active lifecycle labels and derive priority. This increases ambiguity and test complexity.

## Decision: Adapter-owned comments are required for accepted, completed, and failed runs

**Rationale**: Labels alone are not enough for operator auditability. Comments provide a human-readable record while preserving the rule that GitLab writes are controlled by the adapter.

**Alternatives considered**: Let the agent write comments. This violates the token boundary.

## Decision: Fix or isolate shell compatibility failures before claiming full-suite validation

**Rationale**: Existing `core_test` failures prevent a credible full-suite result. The failure appears related to workspace hook execution under `/usr/bin/sh` encountering shell constructs from `mise`, so it must be investigated separately from GitLab behavior.

**Alternatives considered**: Exclude failing tests. This would not satisfy the stabilization goal.

## Decision: Execute local workspace hooks with bash when available

**Rationale**: The failing `core_test.exs:1003` path used a simple `after_create` hook, but local hooks were executed as `sh -lc`. In this environment, login shell setup triggered bash-specific `mise` shell code under `/usr/bin/sh`, producing `[[: not found` and `export: Illegal option -a`. The rest of Symphony already depends on bash for Codex app-server startup, so using bash for local hooks is consistent and resolves the shell portability failure without weakening hook behavior.

**Alternatives considered**: Change only the test fixture, ignore the failure, or strip login-shell behavior. Changing only the fixture would leave production hooks exposed to the same environment issue. Ignoring the failure would violate the full-suite stabilization goal. Removing login semantics would be a larger behavior change for hooks that expect shell initialization.

## Decision: Remove GitLab credentials from local Codex process environment

**Rationale**: `GITLAB_API_TOKEN` and `GITLAB_WEBHOOK_SECRET` may be configured through environment variables for the adapter. Local Codex app-server processes inherit the host environment by default, which would undermine the adapter-owned mutation boundary. Explicitly unsetting GitLab credentials when launching Codex preserves the control-plane token boundary.

**Alternatives considered**: Rely on operators not to expose tokens in the environment. This is too weak for a documented safety boundary.
