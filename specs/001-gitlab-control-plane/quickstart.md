# Quickstart: GitLab Control Plane Demo

## 1. Configure GitLab Labels

Create labels in the GitLab project:

- `soc::queued`
- `soc::claimed`
- `soc::running`
- `soc::waiting-input`
- `soc::human-review`
- `soc::rework`
- `soc::failed`
- `soc::done`

## 2. Configure Token and Webhook Secret

Create a GitLab token for the adapter with API access sufficient to read issues, create issue notes, and update issue labels. Store it outside the repository:

```bash
export GITLAB_API_TOKEN=...
export GITLAB_WEBHOOK_SECRET=...
```

Use a token that can mutate project issues through the GitLab API. `read_api`
is read-only and is not sufficient for issue notes or label updates. Do not
grant repository write scopes for this control-plane phase.

## 3. Configure `WORKFLOW.md`

```yaml
tracker:
  kind: gitlab
  endpoint: https://gitlab.com
  api_key: $GITLAB_API_TOKEN
  project_slug: group/project
  webhook_secret: $GITLAB_WEBHOOK_SECRET
  state_path: /var/lib/symphony/gitlab-control-plane-state.json
  writeback_max_attempts: 3
  writeback_base_backoff_ms: 250
  active_states: ["soc::queued"]
  terminal_states: ["soc::done", "soc::failed"]
```

For disposable local testing, `state_path` may be omitted. For longer-running
staging or production, set it to durable storage outside workspace cleanup.
`active_states` controls polling discovery. During GitLab reconciliation,
Symphony also recognizes `soc::claimed`, `soc::running`, and
`soc::waiting-input` as controlled in-progress lifecycle labels so a long turn
is not stopped merely because it has left the queue.

## 4. Start Symphony with HTTP Enabled

```bash
cd elixir
mise exec -- ./bin/symphony ./WORKFLOW.md --port 8080
```

## 5. Configure GitLab Webhook

In GitLab project webhooks:

- URL: `https://<your-host>/api/v1/gitlab/webhook`
- Secret token: same value as `GITLAB_WEBHOOK_SECRET`
- Events: issue comments / note events. Issue events may be enabled but are not dispatching in this phase.

## 6. Demo Workflow

1. Open a GitLab issue.
2. Comment `/soc run`.
3. Confirm Symphony posts an acknowledgement comment.
4. Confirm labels transition to `soc::queued`, then `soc::running`, then `soc::human-review` on normal completion.
5. Simulate failure and confirm `soc::failed` plus failure comment.

## 7. Restart-Safety Check

1. After a successful `/soc run`, restart Symphony.
2. Replay the same GitLab webhook delivery from GitLab's webhook delivery UI or
   API.
3. Confirm Symphony returns duplicate status and does not add another queued
   label transition, acknowledgement comment, completion comment, or failure
   comment.
4. Confirm the state file exists at `tracker.state_path` and contains
   `webhook_events` and `writebacks` records without secrets.

## 8. Failure Recovery

- Temporary GitLab API failures are retried with bounded backoff.
- Exhausted writeback failures are recorded under `writebacks` in the persistent
  state file.
- Fix GitLab permissions, token validity, webhook reachability, or API
  availability before issuing a new `/soc run`.
- Stop Symphony before any emergency manual state-file repair.

## Known Limitations

- Persistent idempotency is local to one Symphony deployment. Multi-replica
  production requires a shared durable state backend.
- If the persistent state file is deleted or stored on ephemeral disk, replay
  protection and duplicate lifecycle comment suppression reset.
- Branch and merge request creation are not part of this phase.
- Cortex, IOC enrichment, responder actions, SOC UI, endpoint isolation, and automatic blocking are future phases.
- GitLab issue IID is used as the tracker issue ID for this phase.

## Stage 2 Live Staging Validation

For disposable-project live validation, use
[live-staging-validation.md](live-staging-validation.md). It records the
required project labels, token scope, webhook settings, environment variables,
success path, duplicate `/soc run` check, failure path, token-boundary check,
and evidence table.

## Stage 3.5 Real Codex Runner Validation

The helper can generate a workflow that executes a real authenticated local
Codex app-server while preserving the GitLab credential boundary:

```bash
specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh write-workflow real-success
```

The wrapper records only whether `GITLAB_API_TOKEN` and
`GITLAB_WEBHOOK_SECRET` are absent from the child process. It does not record
their values. Use `write-workflow real-failure` only to validate deterministic
startup-failure mapping; it invokes the real Codex executable with an invalid
CLI option and is not a model-turn failure simulation.

The generated workflow sets `codex.approval_policy: never` for app-server
version compatibility. Start Symphony with its required risk acknowledgement
flag. If the default Codex state directory is unhealthy, use a temporary
external `CODEX_HOME` containing only a mode-`0600` copy of `auth.json`.
