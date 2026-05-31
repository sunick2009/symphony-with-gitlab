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

## Required Token Properties

- Token type: project access token or approved project-scoped bot credential
- Required scope: `api`
- Expected role: Maintainer
- Rejected for the initial implementation path:
  - `write_repository`
  - registry scopes
  - runner management scopes
  - GitLab Duo scopes

## Validation Outline

1. Prepare labels and webhook exactly as Stage 3.5 requires.
2. Add or confirm a disposable repository target branch, typically the default branch.
3. Trigger `/soc run` on a staging issue that produces a bounded artifact set.
4. Verify:
   - one deterministic source branch is created
   - one commit is created through the adapter path
   - one MR is opened against the configured target branch
   - the issue receives the MR link and moves to `soc::human-review`
5. Observe MR pipeline status and verify issue writeback for:
   - pending or running
   - success
   - failure or canceled
6. Re-run the same completion path or restart Symphony and verify duplicate suppression.
7. Record token-boundary evidence that `GITLAB_API_TOKEN` and `GITLAB_WEBHOOK_SECRET` remain absent from the Codex process.

## Expected Validation Evidence

- Issue URL
- Source branch name
- Commit SHA
- MR URL and IID
- Latest observed pipeline ID and status
- Issue note excerpts for MR link and CI result
- Sanitized token-boundary trace
- Evidence that retries did not create duplicate branches or merge requests
