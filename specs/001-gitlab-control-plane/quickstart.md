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

## 3. Configure `WORKFLOW.md`

```yaml
tracker:
  kind: gitlab
  endpoint: https://gitlab.com
  api_key: $GITLAB_API_TOKEN
  project_slug: group/project
  webhook_secret: $GITLAB_WEBHOOK_SECRET
  active_states: ["soc::queued"]
  terminal_states: ["soc::done", "soc::failed"]
```

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

## Known Limitations

- Webhook idempotency is in-memory and resets on service restart.
- Branch and merge request creation are not part of this phase.
- Cortex, IOC enrichment, responder actions, SOC UI, endpoint isolation, and automatic blocking are future phases.
- GitLab issue IID is used as the tracker issue ID for this phase.

## Stage 2 Live Staging Validation

For disposable-project live validation, use
[live-staging-validation.md](live-staging-validation.md). It records the
required project labels, token scope, webhook settings, environment variables,
success path, duplicate `/soc run` check, failure path, token-boundary check,
and evidence table.
