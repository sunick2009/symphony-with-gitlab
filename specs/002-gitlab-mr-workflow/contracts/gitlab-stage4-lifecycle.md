# Contract: GitLab Stage 4 Lifecycle

## Purpose

Define the Stage 4 control-plane contract between the orchestrator, the GitLab adapter, and staging validation.

## End-to-End Flow

```text
GitLab issue
-> /agent run note
-> /soc run compatibility alias
-> webhook validation
-> queue / claim / running lifecycle
-> Codex agent run in isolated workspace
-> adapter artifact collection
-> adapter branch creation or reuse
-> adapter commit creation or reuse
-> adapter merge request creation or reuse
-> adapter issue writeback with MR link
-> issue label -> soc::human-review
-> adapter CI reconciliation
-> adapter issue writeback for CI success or failure
```

## Mutation Ownership Contract

1. The Codex agent may produce files, patches, summaries, or metadata inside the isolated workspace.
2. The adapter is solely responsible for:
   - collecting approved outputs
   - validating paths and action types
   - constructing commit actions
   - creating or reusing branches
   - creating commits
   - creating or reusing merge requests
   - reading MR pipeline status
   - writing issue notes and lifecycle transitions
3. The agent process must not receive:
   - `GITLAB_API_TOKEN`
   - `GITLAB_WEBHOOK_SECRET`
   - repository remotes or helper credentials that permit direct push

## Branch Naming Contract

- Pattern: `soc/issue-<iid>/<run-fingerprint>`
- `<iid>`: originating GitLab issue IID
- `<run-fingerprint>`: stable short digest of the approved artifact manifest
- Characters must satisfy GitLab branch naming restrictions used by the Branches API.

## Duplicate Suppression Contract

- Persist one mutation record keyed by `issue_iid + run_fingerprint`.
- Before creating a branch, query or verify whether the branch already exists.
- Before creating an MR, query whether an open MR already uses the deterministic source branch and target branch.
- Before writing issue notes, use idempotent writeback keys exactly as Stage 3 does for lifecycle comments.

## CI Mapping Contract

- Initial MR creation:
  - issue note with MR URL and source branch
  - issue lifecycle moves to `soc::human-review`
- CI pending or running:
  - optional progress note, idempotent by status class
- CI success:
  - issue remains `soc::human-review`
  - success note references MR and pipeline
- CI failure or canceled:
  - MR remains open
  - issue remains visible for operator review
  - failure note references MR and pipeline result

## Staging Validation Contract

- Use only a disposable staging project.
- Do not target production repositories.
- Do not allow the agent to push directly.
- Validate both:
  - repository mutation correctness
  - token-boundary preservation inside the real local Codex runner
