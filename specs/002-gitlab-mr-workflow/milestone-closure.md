# Stage 4 GitLab Integration Milestone Closure

## Scope

This note closes the staging-scoped GitLab integration milestone for the
Symphony control plane. The completed path is:

```text
/soc run
-> GitLab webhook validation
-> adapter-owned queue/claim/run lifecycle
-> artifact manifest validation
-> adapter-owned branch/commit/MR mutation
-> MR-link writeback
-> CI reconciliation
-> restart-safe recovery for partial remote success
```

No new product features are introduced by this closure note.

## Completed Capabilities

- GitLab issue and note webhook handling with secret validation
- `/soc run` parsing and duplicate command suppression
- adapter-owned issue label transitions and lifecycle comments
- dry-run Stage 4 artifact planning with deterministic manifest and action
  digests
- staging-gated live branch creation, commit creation, and merge request
  creation through the GitLab REST API
- idempotent MR-link writeback
- CI reconciliation against the newest relevant MR pipeline with normalized
  status classes
- idempotent CI success/failure comment writeback
- deterministic recovery for partial remote success when local state is missing
- provenance mismatch blocking for unsafe branch or MR reuse

## Sanitized Staging Validation Evidence

- Stage 4.2 live MR creation succeeded on 2026-05-31 using issue `#19`,
  branch `soc/issue-19/fdabb4c741ea`, commit `eee92b65`, and MR `!1`.
- Stage 4.3.1 disposable CI success validation succeeded on 2026-05-31 using
  issue `#23`, MR `!2`, branch `soc/issue-23/1ac473b8b3cd`, and pipeline `#44`.
  Exactly one CI success comment was written. The MR remained open and the
  issue remained `soc::human-review`.
- Stage 4.3.1 disposable CI failure validation succeeded on 2026-05-31 using
  issue `#24`, MR `!3`, branch `soc/issue-24/eddfd104b71d`, and pipeline `#45`.
  Exactly one CI failure comment was written. The MR remained open and the
  issue remained `soc::human-review`.
- Duplicate reconciliation did not create a second branch, commit, MR, MR-link
  comment, or CI result comment for the validated staging samples.

## Security and Ownership Boundaries

- GitLab write tokens and webhook secrets remain outside the Codex agent
  process.
- Adapter-owned mutation remains mandatory for branch creation, commit
  creation, merge request creation, issue comments, issue label transitions,
  and CI writeback.
- Credentialed agent-owned `git push` remains disallowed.
- Sanitized local token-boundary traces continued to show
  `GITLAB_API_TOKEN=unset` and `GITLAB_WEBHOOK_SECRET=unset`.

## Remaining Non-Production Limitations

- The state store remains local file-backed state for one Symphony deployment.
  Multi-node deployment requires shared or centralized state.
- CI reconciliation remains polling-based.
- Restart-hardening relies on deterministic Stage 4 provenance markers and
  matching MR metadata rather than full remote repository content diffing.
- Remote-worker token boundary is still validated only for local staging paths,
  not for a real external worker fleet.
- The milestone is staging validated only. It is not a production rollout.

## Explicit Out Of Scope

- Cortex integration
- IOC enrichment
- responder actions
- SOC UI
- automatic merge
- production GitLab project targeting
- endpoint isolation or blocking actions
- multi-node production deployment

