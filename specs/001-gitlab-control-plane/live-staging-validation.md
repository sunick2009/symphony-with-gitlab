# Stage 2: Live GitLab Staging Validation

**Status**: Not executed in this workspace yet.

**Reason**: No staging GitLab environment variables were present when checked on 2026-05-30:

```bash
env | rg '^(GITLAB|SYMPHONY|MIX_ENV|PHX|PORT)=' | sed -E 's/=.*/=<set>/'
```

The command returned no matching variables. Do not mark Stage 2 complete until the live staging evidence sections below are filled with real staging issue URLs and command results.

## Scope

This checklist validates the already completed `001-gitlab-control-plane` implementation against a disposable GitLab staging project. It must not introduce product behavior beyond the spec.

The live workflow under validation is:

```text
GitLab issue/comment
-> /soc run
-> webhook validation
-> command parsing
-> queue/claim
-> polling discovery
-> orchestrator lifecycle
-> adapter-owned label/comment writeback
-> soc::human-review on success
-> soc::failed on failure
```

## Hard Boundaries

- Use only a disposable staging project.
- Use a project-scoped bot token where available.
- Do not use production projects or real SOC data.
- Do not request or grant `write_repository`.
- Do not create branches or merge requests.
- Do not enable Cortex, IOC enrichment, responder actions, SOC UI, endpoint isolation, or automatic blocking.
- Do not pass `GITLAB_API_TOKEN` or `GITLAB_WEBHOOK_SECRET` into Codex local or remote processes.
- Record environment variable names and whether they are set, but never record secret values.

## Official GitLab References

- Project access tokens: https://docs.gitlab.com/user/project/settings/project_access_tokens/
- Project webhooks: https://docs.gitlab.com/user/project/integrations/webhooks/
- Webhook comment events: https://docs.gitlab.com/user/project/integrations/webhook_events/
- Issues API: https://docs.gitlab.com/api/issues/
- Notes API: https://docs.gitlab.com/api/notes/
- Labels API: https://docs.gitlab.com/api/labels/

Relevant current GitLab behavior:

- Project access tokens authenticate to the GitLab API and are scoped to one project.
- For project access tokens, `api` grants read and write access to the scoped project API; `read_api` is read-only and is not sufficient for issue comments or label mutation.
- New webhooks should prefer signing tokens when the receiver supports signature verification. The current Symphony implementation validates `X-Gitlab-Token`, so this Stage 2 run must configure the GitLab webhook secret token to match `GITLAB_WEBHOOK_SECRET`.
- GitLab comment events use `X-Gitlab-Event: Note Hook`; issue comments include target issue data in the payload.
- Issue label mutation is available through the Issues API with `add_labels` and `remove_labels`.
- Issue note creation is available through the Notes API.
- Project label creation is available through the Labels API.

## Required Staging Configuration

Set these variables in the shell that starts Symphony and runs the validation commands:

```bash
export GITLAB_ENDPOINT=https://gitlab.com
export GITLAB_PROJECT_ID=<numeric staging project id>
export GITLAB_PROJECT_SLUG=<group-or-namespace/staging-project>
export GITLAB_API_TOKEN=<project bot token, secret, do not print>
export GITLAB_WEBHOOK_SECRET=<webhook secret, secret, do not print>
export GITLAB_WEBHOOK_PUBLIC_URL=https://<public-url>/api/v1/gitlab/webhook
export STAGE2_CONFIRM_DISPOSABLE_PROJECT=yes
export STAGE2_RUN_ID=symphony-stage2-$(date -u +%Y%m%dT%H%M%SZ)
```

Required token properties:

- Token type: project access token or another project-scoped bot credential approved for the disposable staging project.
- Scope: `api`.
- Role: Maintainer is the expected role because the validation mutates issue labels and creates issue comments.
- Forbidden scopes: `write_repository`, registry scopes, runner management scopes, and GitLab Duo scopes.
- Expiration: short-lived, with revocation planned immediately after Stage 2.

Required labels:

```text
soc::queued
soc::claimed
soc::running
soc::waiting-input
soc::human-review
soc::rework
soc::failed
soc::done
```

Webhook settings:

- URL: value of `GITLAB_WEBHOOK_PUBLIC_URL`.
- Secret token: value of `GITLAB_WEBHOOK_SECRET`.
- Events: comments / note events are required. Issue events are optional and must not be used as a dispatch trigger.
- SSL verification: enabled for any HTTPS public URL.

## Scripted Validation Sequence

The helper script stores evidence under `${STAGE2_EVIDENCE_DIR:-/tmp/symphony-stage2/evidence}` and refuses to run GitLab writes unless `STAGE2_CONFIRM_DISPOSABLE_PROJECT=yes`.

Use this sequence after configuring the staging project webhook and exporting the required environment variables:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh preflight
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh ensure-labels
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh write-workflow success

cd elixir
mix setup
mix build
./bin/symphony /tmp/symphony-stage2/WORKFLOW.stage2.md --port 8080
```

In another shell with the same exported environment:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh create-success-issue
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh post-run success
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh poll success
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh notes success
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh post-run duplicate
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh notes success
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh token-boundary
```

Then restart Symphony after switching the fake Codex command to failure mode:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh write-workflow failure
```

After Symphony is running again:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh create-failure-issue
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh post-run failure
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh poll failure
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh notes failure
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh token-boundary
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh evidence-summary
```

## Preflight Commands

These commands intentionally avoid printing secret values.

Preferred scripted path:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh preflight
```

Equivalent manual checks:

```bash
test -n "${GITLAB_ENDPOINT:-}" && echo "GITLAB_ENDPOINT=<set>"
test -n "${GITLAB_PROJECT_ID:-}" && echo "GITLAB_PROJECT_ID=<set>"
test -n "${GITLAB_PROJECT_SLUG:-}" && echo "GITLAB_PROJECT_SLUG=<set>"
test -n "${GITLAB_API_TOKEN:-}" && echo "GITLAB_API_TOKEN=<set>"
test -n "${GITLAB_WEBHOOK_SECRET:-}" && echo "GITLAB_WEBHOOK_SECRET=<set>"
test -n "${GITLAB_WEBHOOK_PUBLIC_URL:-}" && echo "GITLAB_WEBHOOK_PUBLIC_URL=<set>"
test "${STAGE2_CONFIRM_DISPOSABLE_PROJECT:-}" = "yes" && echo "STAGE2_CONFIRM_DISPOSABLE_PROJECT=<set>"
```

```bash
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
  "${GITLAB_ENDPOINT}/api/v4/projects/${GITLAB_PROJECT_ID}" \
  | jq '{id, path_with_namespace, web_url, visibility}'
```

Expected result: the returned project is the disposable staging project and not a production project.

## Label Setup Commands

Create missing labels. Existing labels may return a conflict response; record that as acceptable if the label already exists.

Preferred scripted path:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh ensure-labels
```

Equivalent manual command:

```bash
for label in \
  'soc::queued' \
  'soc::claimed' \
  'soc::running' \
  'soc::waiting-input' \
  'soc::human-review' \
  'soc::rework' \
  'soc::failed' \
  'soc::done'
do
  curl --silent --show-error \
    --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
    --data-urlencode "name=${label}" \
    --data-urlencode "color=#428BCA" \
    "${GITLAB_ENDPOINT}/api/v4/projects/${GITLAB_PROJECT_ID}/labels" \
    | jq '{name, message}'
done
```

## Workflow File for Live Validation

Create the file outside the repository if possible, for example `/tmp/symphony-stage2/WORKFLOW.stage2.md`:

```yaml
agent:
  codex:
    command: /tmp/symphony-stage2/fake-codex-success app-server

tracker:
  kind: gitlab
  endpoint: $GITLAB_ENDPOINT
  api_key: $GITLAB_API_TOKEN
  project_slug: $GITLAB_PROJECT_SLUG
  webhook_secret: $GITLAB_WEBHOOK_SECRET
  active_states: ["soc::queued"]
  terminal_states: ["soc::done", "soc::failed"]

workspace:
  root: /tmp/symphony-stage2/workspaces

polling:
  interval_ms: 1000
```

For live Stage 2, the fake Codex command is acceptable only for validating GitLab control-plane mechanics and token boundary. A later Codex-agent validation may replace it with a real Codex command if the staging environment has valid Codex credentials and the run remains scoped to synthetic staging data.

## Local Codex Token Boundary Probe

Create a fake Codex command that records only whether GitLab variables are visible to the agent process:

Preferred scripted path:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh write-workflow success
```

Equivalent manual setup:

```bash
mkdir -p /tmp/symphony-stage2
cat > /tmp/symphony-stage2/fake-codex-success <<'SH'
#!/bin/sh
trace_file="${SYMPHONY_STAGE2_AGENT_TRACE:-/tmp/symphony-stage2/agent-env.trace}"
{
  printf 'GITLAB_API_TOKEN=%s\n' "${GITLAB_API_TOKEN-unset}"
  printf 'GITLAB_WEBHOOK_SECRET=%s\n' "${GITLAB_WEBHOOK_SECRET-unset}"
} >> "$trace_file"

count=0
while IFS= read -r line; do
  count=$((count + 1))
  case "$count" in
    1) printf '%s\n' '{"id":1,"result":{}}' ;;
    2) printf '%s\n' '{"id":2,"result":{"thread":{"id":"stage2-thread-success"}}}' ;;
    3) printf '%s\n' '{"id":3,"result":{"turn":{"id":"stage2-turn-success"}}}' ;;
    4) printf '%s\n' '{"method":"turn/completed"}'; exit 0 ;;
    *) exit 0 ;;
  esac
done
SH
chmod 755 /tmp/symphony-stage2/fake-codex-success
export SYMPHONY_STAGE2_AGENT_TRACE=/tmp/symphony-stage2/agent-env.trace
```

Expected trace after a run:

```text
GITLAB_API_TOKEN=unset
GITLAB_WEBHOOK_SECRET=unset
```

## Start Symphony

```bash
cd elixir
mix setup
mix build
./bin/symphony /tmp/symphony-stage2/WORKFLOW.stage2.md --port 8080
```

The webhook receiver must be publicly reachable at `GITLAB_WEBHOOK_PUBLIC_URL`. Use an approved staging tunnel or staging deployment. Record the tunnel or deployment identifier without embedding secrets.

## Success Path Validation

Create a staging issue with synthetic content:

Preferred scripted path:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh create-success-issue
```

Equivalent manual command:

```bash
SUCCESS_TITLE="${STAGE2_RUN_ID} success path"
SUCCESS_ISSUE_JSON=$(
  curl --fail --silent --show-error \
    --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
    --data-urlencode "title=${SUCCESS_TITLE}" \
    --data-urlencode "description=Synthetic Stage 2 success-path issue. No SOC data." \
    "${GITLAB_ENDPOINT}/api/v4/projects/${GITLAB_PROJECT_ID}/issues"
)
SUCCESS_IID=$(printf '%s' "$SUCCESS_ISSUE_JSON" | jq -r '.iid')
SUCCESS_URL=$(printf '%s' "$SUCCESS_ISSUE_JSON" | jq -r '.web_url')
printf 'SUCCESS_IID=%s\nSUCCESS_URL=%s\n' "$SUCCESS_IID" "$SUCCESS_URL"
```

Trigger the workflow through GitLab so the real webhook is delivered:

Preferred scripted path:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh post-run success
```

Equivalent manual command:

```bash
curl --fail --silent --show-error \
  --request POST \
  --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
  --data-urlencode "body=/soc run" \
  "${GITLAB_ENDPOINT}/api/v4/projects/${GITLAB_PROJECT_ID}/issues/${SUCCESS_IID}/notes" \
  | jq '{id, body, created_at, web_url}'
```

Poll until the issue reaches `soc::human-review`:

Preferred scripted path:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh poll success
```

Equivalent manual command:

```bash
for _ in $(seq 1 60); do
  issue=$(
    curl --fail --silent --show-error \
      --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
      "${GITLAB_ENDPOINT}/api/v4/projects/${GITLAB_PROJECT_ID}/issues/${SUCCESS_IID}"
  )
  labels=$(printf '%s' "$issue" | jq -r '.labels | join(",")')
  printf '%s labels=%s\n' "$(date -u +%H:%M:%S)" "$labels"
  printf '%s' "$issue" | jq -e '.labels | index("soc::human-review")' >/dev/null && break
  sleep 2
done
```

Verify comments:

Preferred scripted path:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh notes success
```

Equivalent manual command:

```bash
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
  "${GITLAB_ENDPOINT}/api/v4/projects/${GITLAB_PROJECT_ID}/issues/${SUCCESS_IID}/notes" \
  | jq '[.[] | {id, body, created_at}]'
```

Expected evidence:

- One acknowledgement comment containing `Symphony accepted`.
- One completion comment containing `soc::human-review`.
- Final labels include `soc::human-review`.
- Final labels do not include `soc::queued`, `soc::claimed`, or `soc::running`.
- Agent trace shows GitLab secrets as `unset`.

## Duplicate `/soc run` Validation

Post the same command again to the success issue:

Preferred scripted path:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh post-run duplicate
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh notes success
```

Equivalent manual command:

```bash
curl --fail --silent --show-error \
  --request POST \
  --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
  --data-urlencode "body=/soc run" \
  "${GITLAB_ENDPOINT}/api/v4/projects/${GITLAB_PROJECT_ID}/issues/${SUCCESS_IID}/notes" \
  | jq '{id, body, created_at, web_url}'
```

Expected evidence:

- No second orchestrator run is started.
- No duplicate completion comment appears.
- The issue remains in `soc::human-review`.

Note: the current spec guarantees in-memory duplicate webhook delivery handling and rejects duplicate run commands for `soc::claimed` or `soc::running`. It does not yet reject `/soc run` on `soc::human-review`. If this live check creates a second run after terminal handoff, record it as a Stage 2 gap rather than changing scope silently.

## Failure Path Validation

Stop Symphony, replace the fake Codex command with a failing command, and restart Symphony with the same workflow path:

Preferred scripted path:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh write-workflow failure
```

Equivalent manual command:

```bash
cat > /tmp/symphony-stage2/fake-codex-success <<'SH'
#!/bin/sh
trace_file="${SYMPHONY_STAGE2_AGENT_TRACE:-/tmp/symphony-stage2/agent-env.trace}"
{
  printf 'GITLAB_API_TOKEN=%s\n' "${GITLAB_API_TOKEN-unset}"
  printf 'GITLAB_WEBHOOK_SECRET=%s\n' "${GITLAB_WEBHOOK_SECRET-unset}"
} >> "$trace_file"
exit 42
SH
chmod 755 /tmp/symphony-stage2/fake-codex-success
```

Create and trigger a failure issue:

Preferred scripted path:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh create-failure-issue
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh post-run failure
```

Equivalent manual command:

```bash
FAIL_TITLE="${STAGE2_RUN_ID} failure path"
FAIL_ISSUE_JSON=$(
  curl --fail --silent --show-error \
    --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
    --data-urlencode "title=${FAIL_TITLE}" \
    --data-urlencode "description=Synthetic Stage 2 failure-path issue. No SOC data." \
    "${GITLAB_ENDPOINT}/api/v4/projects/${GITLAB_PROJECT_ID}/issues"
)
FAIL_IID=$(printf '%s' "$FAIL_ISSUE_JSON" | jq -r '.iid')
FAIL_URL=$(printf '%s' "$FAIL_ISSUE_JSON" | jq -r '.web_url')
printf 'FAIL_IID=%s\nFAIL_URL=%s\n' "$FAIL_IID" "$FAIL_URL"

curl --fail --silent --show-error \
  --request POST \
  --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
  --data-urlencode "body=/soc run" \
  "${GITLAB_ENDPOINT}/api/v4/projects/${GITLAB_PROJECT_ID}/issues/${FAIL_IID}/notes" \
  | jq '{id, body, created_at, web_url}'
```

Poll until `soc::failed`:

Preferred scripted path:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh poll failure
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh notes failure
```

Equivalent manual command:

```bash
for _ in $(seq 1 60); do
  issue=$(
    curl --fail --silent --show-error \
      --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
      "${GITLAB_ENDPOINT}/api/v4/projects/${GITLAB_PROJECT_ID}/issues/${FAIL_IID}"
  )
  labels=$(printf '%s' "$issue" | jq -r '.labels | join(",")')
  printf '%s labels=%s\n' "$(date -u +%H:%M:%S)" "$labels"
  printf '%s' "$issue" | jq -e '.labels | index("soc::failed")' >/dev/null && break
  sleep 2
done
```

Expected evidence:

- One acknowledgement comment containing `Symphony accepted`.
- One failure comment containing `soc::failed`.
- Final labels include `soc::failed`.
- Final labels do not include `soc::queued`, `soc::claimed`, or `soc::running`.
- Agent trace shows GitLab secrets as `unset`.

Verify local token boundary:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh token-boundary
```

## Remote Token Boundary Validation

If the staging run uses remote workers, verify both sides:

1. The Symphony host environment contains `GITLAB_API_TOKEN` and `GITLAB_WEBHOOK_SECRET`.
2. The remote agent launch command unsets `GITLAB_API_TOKEN` and `GITLAB_WEBHOOK_SECRET` before executing Codex.
3. Remote trace or process instrumentation records only `unset` for both variables.

If no remote worker is used in Stage 2, record this as `not exercised` rather than `passed`.

## Evidence Log

Fill this table during the live run.

| Check | Evidence | Result |
| --- | --- | --- |
| Staging project confirmed non-production | Pending | Pending |
| Required labels exist | Pending | Pending |
| Webhook configured with note events and secret token | Pending | Pending |
| Symphony process started with staging workflow | Pending | Pending |
| Success issue URL | Pending | Pending |
| `/soc run` acknowledgement comment | Pending | Pending |
| `soc::queued` observed | Pending | Pending |
| `soc::running` observed | Pending | Pending |
| `soc::human-review` observed | Pending | Pending |
| Completion comment observed | Pending | Pending |
| Duplicate `/soc run` did not create a duplicate run | Pending | Pending |
| Failure issue URL | Pending | Pending |
| `soc::failed` observed | Pending | Pending |
| Failure comment observed | Pending | Pending |
| Local Codex process did not receive GitLab secrets | Pending | Pending |
| Remote Codex process did not receive GitLab secrets, if used | Pending | Pending |
| No branch or merge request created | Pending | Pending |
| No out-of-scope SOC action executed | Pending | Pending |

## Current Results

No live staging calls were executed in this workspace because the required staging environment variables are not set.

Commands run so far:

```bash
env | rg '^(GITLAB|SYMPHONY|MIX_ENV|PHX|PORT)=' | sed -E 's/=.*/=<set>/'
```

Result: no output.

## Remaining Risks

- Live webhook delivery cannot be proven until `GITLAB_WEBHOOK_PUBLIC_URL` reaches the local or staging Symphony server.
- The current implementation validates GitLab `X-Gitlab-Token`; GitLab documentation recommends signing tokens for new webhooks when supported. Signing-token validation is not in the Stage 1 spec and should be treated as future hardening.
- In-memory webhook idempotency resets on Symphony restart.
- Duplicate `/soc run` after terminal `soc::human-review` may reveal a Stage 2 gap because Stage 1 explicitly rejects claimed/running states, not all terminal states.
- Remote worker token boundary remains unverified unless Stage 2 uses a remote worker.
