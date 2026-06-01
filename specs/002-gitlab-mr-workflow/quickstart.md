# Quickstart: Stage 4 GitLab MR Workflow Validation

## Purpose

Validate the Stage 4 branch, commit, merge request, and CI writeback workflow against a disposable GitLab staging project only.

## Hard Boundaries

- Use only a disposable staging project.
- Do not connect to production GitLab projects.
- Do not expose GitLab write tokens or webhook secrets to the Codex runner.
- Do not allow the agent process to execute `git push` with GitLab credentials.
- Do not enable Cortex, IOC enrichment, responder actions, SOC UI, endpoint isolation, automatic blocking, or auto-merge.

## Required Staging Configuration

Set these environment variables for the Symphony process and validation commands:

```bash
export GITLAB_ENDPOINT=https://gitlab.example.com
export GITLAB_PROJECT_SLUG=<group/staging-project>
export GITLAB_API_TOKEN=<project access token with api scope>
export GITLAB_WEBHOOK_SECRET=<webhook secret>
export GITLAB_STATE_PATH=/tmp/symphony-stage4/gitlab-state.json
export STAGE4_CONFIRM_DISPOSABLE_PROJECT=yes
export STAGE4_RUN_ID=symphony-stage4-$(date -u +%Y%m%dT%H%M%SZ)
```

Set these `WORKFLOW.md` values for live staging MR creation:

```yaml
tracker:
  kind: gitlab
  endpoint: https://gitlab.example.com
  api_key: $GITLAB_API_TOKEN
  project_slug: <group/staging-project>
  webhook_secret: $GITLAB_WEBHOOK_SECRET
  state_path: /tmp/symphony-stage4/gitlab-state.json
  stage4_live_mutation: true
  stage4_allowed_project_slugs: ["<group/staging-project>"]
```

## Required Token Properties

- Token type: project access token or approved project-scoped bot credential
- Required scope: `api`
- Expected role: Maintainer
- Rejected for the initial implementation path:
  - `write_repository`
  - registry scopes
  - runner management scopes
  - GitLab Duo scopes

Live mutation stays disabled by default. Setting `tracker.stage4_live_mutation:
true` is insufficient by itself; `tracker.project_slug` must also be present in
`tracker.stage4_allowed_project_slugs`, otherwise Symphony blocks live
repository mutation and records a Stage 4 finalization error instead.

## Validation Outline

1. Prepare labels and webhook exactly as Stage 3.5 requires.
2. Add or confirm a disposable repository target branch, typically the default branch.
3. Produce a bounded artifact manifest at `.symphony/gitlab_artifacts.json`.
4. Trigger `/soc run` on a staging issue that produces the approved artifact set.
5. For the helper-based validation path, you may use:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh write-workflow stage4-live
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh create-stage4-issue
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh post-run success
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh poll success
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh verify-stage4-live
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh verify-stage4-ci
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh token-boundary
```

For a disposable CI-success run, use `write-workflow stage4-live-success`.
For a disposable CI-failure run, use `write-workflow stage4-live-failure`.
These helper workflows pin `agent.max_turns: 1` so the fake local Codex
runner does not trigger an artificial continuation-turn failure during staging
validation.

4. Verify:
   - one deterministic source branch is created
   - one commit is created through the adapter path
   - one MR is opened against the configured target branch
   - the issue receives the MR link and moves to `soc::human-review`
6. Observe MR pipeline status and verify issue writeback for:
   - pending or running
   - success
   - failure or canceled
   - skipped or unknown, if returned by GitLab
7. Re-run the same completion path or restart Symphony and verify duplicate suppression.
8. Record token-boundary evidence that `GITLAB_API_TOKEN` and `GITLAB_WEBHOOK_SECRET` remain absent from the Codex process.

## CI Reconciliation Behavior

- Symphony fetches pipelines using the stored MR IID.
- It filters to the stored source branch when GitLab returns a branch ref.
- It selects the newest relevant pipeline deterministically using `updated_at`
  and pipeline ID.
- Normalized status classes are:
  - `ci-pending`
  - `ci-running`
  - `ci-success`
  - `ci-failure`
  - `ci-unknown`
- CI success and failure both leave the MR open and the issue in
  `soc::human-review`.
- Example CI issue writeback:
  `Symphony observed CI status \`success\` for merge request <mr-url> on pipeline \`123\`.`
- Auto-merge is out of scope.

## Expected Validation Evidence

- Issue URL
- Source branch name
- Expected branch pattern: `soc/issue-<iid>/<run-fingerprint>`
- Expected commit message prefix: `chore(gitlab): update issue #<iid> artifacts`
- Expected commit provenance marker: `[stage4:<run-fingerprint>:<action-digest-prefix>]`
- Commit SHA
- MR URL and IID
- Expected MR title: `Issue #<iid>: <issue title>`
- Expected MR description content: issue identifier, manifest digest, and action digest
- Latest observed pipeline ID and status
- Latest observed CI status class
- Issue note excerpts for MR link and CI result
- Sanitized token-boundary trace
- Evidence that retries did not create duplicate branches or merge requests

## Known Limitations

- CI reconciliation is polling-based rather than webhook-driven.
- Partial remote-success recovery is limited to deterministic Stage 4
  provenance. Commit-only recovery relies on the expected commit provenance
  marker on the source branch head, or on a matching open MR.
- If an existing open MR for the deterministic source branch points to an
  unexpected target branch, Symphony blocks live mutation instead of creating a
  second MR.
- Recovery state remains local to the configured `tracker.state_path`. Multi-node
  reconciliation remains out of scope.

## Sanitized Staging Evidence

- Stage 4.2 live MR creation succeeded on 2026-05-31 using staging issue `#19`,
  source branch `soc/issue-19/fdabb4c741ea`, commit `eee92b65`, and merge
  request `!1`.
- Stage 4.3.1 disposable CI-success validation succeeded on 2026-05-31 using
  issue `#23`, merge request `!2`, source branch
  `soc/issue-23/1ac473b8b3cd`, pipeline `#44`, and one CI success note for
  pipeline `44`. The issue remained in `soc::human-review`, the MR remained
  open, and repeated reconciliation left the CI success note count at `1`.
- Stage 4.3.1 disposable CI-failure validation succeeded on 2026-05-31 using
  issue `#24`, merge request `!3`, source branch
  `soc/issue-24/eddfd104b71d`, pipeline `#45`, and one CI failure note for
  pipeline `45`. The issue remained in `soc::human-review`, the MR remained
  open, and repeated reconciliation left the CI failure note count at `1`.
- Sanitized token-boundary evidence remained `Pass` throughout the success and
  failure runs. The local agent trace continued to show
  `GITLAB_API_TOKEN=unset` and `GITLAB_WEBHOOK_SECRET=unset`.

## Rollback and Cleanup

- Close the disposable MR if the validation run is no longer needed.
- Delete the disposable staging branch after confirming no further retry or CI observation is required.
- Preserve the state file until evidence capture is complete; remove it only while Symphony is stopped.
