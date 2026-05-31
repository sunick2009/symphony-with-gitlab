# Research: GitLab Merge Request Workflow

## Decision: Use a new Stage 4 feature directory instead of extending `001-gitlab-control-plane`

**Rationale**: Stage 1-3.5 are complete and already staging-validated. Stage 4 expands the problem from issue lifecycle control into repository mutation and CI reconciliation. A new feature directory keeps the already-accepted stabilization scope intact and makes new risks auditable.

**Alternatives considered**: Continue editing `specs/001-gitlab-control-plane/`. This would blur the boundary between the completed stabilization phase and a new workflow phase with materially different mutation behavior.

## Decision: Require `api` scope for the Stage 4 staging token and reject `write_repository` for the initial implementation

**Rationale**: GitLab project access tokens document that `api` grants read and write access to the scoped project API, while `write_repository` grants repository push access. The Stage 4 design can create branches, commits, merge requests, and issue notes through project APIs, so `api` is sufficient for the chosen path and avoids issuing a token intended for git transport.

**Alternatives considered**: Use `write_repository` and adapter-controlled local `git push`. This would permit fuller git semantics, but it would require a credentialed remote or credential helper on the adapter host and would widen the operational blast radius if the boundary is misconfigured.

## Decision: Prefer GitLab Branches API plus Commits API over credentialed local git push

**Rationale**: The GitLab Branches API can create a branch from a ref, and the Commits API can create a batch commit on a branch, including creating the branch from `start_branch` or `start_sha` when needed. This keeps repository mutation in the same HTTP client boundary already used for labels and issue notes.

**Alternatives considered**: Adapter-controlled local clone plus `git push`, or GitLab Repository Files API per file. Local git push carries broader credential and host-state risk. Repository Files API would fragment one logical change set into many separate writes and makes commit provenance harder to keep atomic.

## Decision: Generate deterministic source branches from issue IID plus artifact-manifest fingerprint

**Rationale**: Branch naming must support idempotency and human audit. A branch name such as `soc/issue-42/ab12cd34` ties the branch to the issue while allowing multiple materially different reruns if the generated artifact set changes.

**Alternatives considered**: Use only the issue IID, use random UUIDs, or use timestamps. Issue-only names prevent safe reruns with revised content. Random or timestamp-only names make duplicate suppression and operator reasoning harder.

## Decision: Reuse existing branches and merge requests only after provenance checks

**Rationale**: Duplicate suppression cannot rely solely on operation keys because the process may crash after GitLab mutation but before local state persistence. Stage 4 should first query whether the deterministic branch exists and whether an open MR already references it. Reuse is safe only if stored provenance or GitLab metadata matches the current issue IID, target branch, and artifact fingerprint.

**Alternatives considered**: Trust only local state or trust any existing branch name match. Trusting only local state is not restart-safe after partial failure. Trusting any branch match risks attaching to unrelated user work.

## Decision: Collect agent outputs through an adapter-owned artifact manifest

**Rationale**: The agent may generate files, patches, summaries, or artifacts, but the adapter must decide what enters the repository mutation step. A manifest-based collector lets the adapter constrain paths, normalize file actions, and reject unsupported output before GitLab writes occur.

**Alternatives considered**: Commit the entire workspace diff or let the agent name arbitrary files for commit. Full-diff collection is too implicit and increases the risk of accidental secret, cache, or irrelevant file capture.

## Decision: Keep merge requests open on both CI success and CI failure

**Rationale**: Stage 4 is still a human-review workflow. CI success means the MR is technically reviewable. CI failure means human operators should inspect the failure before deciding whether to rerun the agent, adjust the change, or close the MR. Auto-closing or auto-merging would exceed the approved automation boundary.

**Alternatives considered**: Auto-merge on success, auto-close on failure, or force issue transition to `soc::rework` automatically. These options create more product impact than the current stage allows.

## Decision: Reflect CI status back to the issue through idempotent notes keyed by status class

**Rationale**: The issue remains the control-plane record for operators. A single idempotent note for MR-created, CI-success, and CI-failure states keeps the issue readable while preserving the existing writeback model.

**Alternatives considered**: Mirror every pipeline event or rely solely on the MR page. Mirroring every event would create noise and more duplicate-suppression complexity. MR-only visibility breaks the control-plane abstraction.

## Decision: Extend the existing file-backed state store for Stage 4

**Rationale**: The current deployment model is still single-node and file-backed. Extending the existing store preserves operational continuity and avoids introducing a database in the same phase as repository mutation.

**Alternatives considered**: Introduce a database or an external queue before Stage 4. That would expand scope substantially and make it difficult to isolate Stage 4 repository workflow concerns.

## Decision: Validate Stage 4 only against a disposable staging project

**Rationale**: Stage 4 introduces repository writes and merge requests. The existing project memory and live validation guidance explicitly prohibit production GitLab usage. A disposable staging project is the only acceptable target for this phase.

**Alternatives considered**: Validate against a shared non-disposable project or a production-adjacent repository. This would weaken the safety boundary and complicate cleanup.
