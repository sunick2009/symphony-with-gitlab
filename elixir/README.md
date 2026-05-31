# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
Linear issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` may be `linear`, `gitlab`, or `memory`. The GitLab support is a control-plane
  foundation: issue polling, label-derived state, webhook command parsing, adapter-owned issue
  comments, and adapter-owned label transitions.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` for Linear or `GITLAB_API_TOKEN` for GitLab when
  unset. Explicit `$ENV_VAR` references are also supported.
- For GitLab, `tracker.endpoint` defaults to `https://gitlab.com`, `tracker.project_slug` is the
  GitLab project path such as `group/project`, and issue state is derived from configured labels.
  Configure `tracker.webhook_secret` or `GITLAB_WEBHOOK_SECRET` before enabling the webhook route.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`. For GitLab, the same
  server also accepts project webhooks at `POST /api/v1/gitlab/webhook`; configure GitLab issue and
  note events with the same secret stored in `tracker.webhook_secret`.

Minimal GitLab control-plane example:

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

### GitLab control-plane setup

GitLab support in this implementation is limited to control-plane operations:
issue polling, issue note webhooks, `/soc` command parsing, issue comments, and
label transitions. It does not create branches or merge requests, and it does
not run Cortex, responder, IOC enrichment, endpoint isolation, or other
production-impacting actions.

Create these labels in the GitLab project before enabling the workflow:

- `soc::queued`
- `soc::claimed`
- `soc::running`
- `soc::waiting-input`
- `soc::human-review`
- `soc::rework`
- `soc::failed`
- `soc::done`

Use a GitLab token that can read project issues, create issue comments, and
update issue labels. For GitLab personal, project, or group access tokens, this
typically requires the `api` scope. GitLab documents `read_api` as read-only,
so it is not sufficient for adapter-owned comments or label mutation. Do not
grant `write_repository`, registry, runner, or AI feature scopes for this
control plane. Store the token outside the repository:

```bash
export GITLAB_API_TOKEN=...
export GITLAB_WEBHOOK_SECRET=...
```

For project access tokens, prefer a project-scoped bot token with the minimum
project role that can update issues. GitLab documents token rotation for
project access tokens; rotation immediately revokes the old token, so update
the Symphony secret and restart or reload the deployment before sending more
webhooks.

Start Symphony with the HTTP server enabled, then configure a GitLab project
webhook:

```bash
./bin/symphony ./WORKFLOW.md --port 8080
```

Webhook settings:

- URL: `https://<your-host>/api/v1/gitlab/webhook`
- Secret token: the same value as `GITLAB_WEBHOOK_SECRET`
- Events: issue comment / note events. Issue events may be enabled, but they do
  not dispatch runs in this phase.
- TLS should terminate at a stable staging or production endpoint. Tunnels are
  acceptable for disposable staging, but not for production.
- The current receiver validates GitLab's `X-Gitlab-Token` secret token. Rotate
  this secret independently from `GITLAB_API_TOKEN` if either value is exposed.

Persistent control-plane state:

- `tracker.state_path` stores webhook replay suppression, lifecycle writeback
  idempotency, issue run-state markers, and sanitized audit records.
- If omitted, the state file defaults to `.gitlab-control-plane-state.json`
  under `workspace.root`.
- For longer-running staging or production, set `tracker.state_path` to a
  durable path outside ephemeral workspace cleanup, such as
  `/var/lib/symphony/gitlab-control-plane-state.json`.
- Back up this file with the same retention expectations as other operational
  state. Losing it does not expose GitLab secrets, but it can allow replayed
  webhook deliveries or lifecycle handlers to perform duplicate writeback.
- The state file must not be committed. It intentionally stores no GitLab API
  token, webhook secret, raw issue body, raw comment body, prompt, or agent
  output.

Writeback retry:

- GitLab issue comments and label updates retry transport errors, HTTP 429, and
  HTTP 5xx responses.
- `tracker.writeback_max_attempts` controls the maximum attempts. Default: `3`.
- `tracker.writeback_base_backoff_ms` controls bounded exponential backoff.
  Default: `250`.
- Permission and validation failures such as HTTP 400, 401, 403, and 404 are
  surfaced without repeated retry.

Sample workflow:

1. Open a GitLab issue.
2. Comment `/soc run` at the beginning of a line.
3. Symphony validates the webhook secret, queues the issue with `soc::queued`,
   and posts an acknowledgement comment.
4. Polling discovers the queued issue and dispatches an isolated agent run.
5. Dispatch moves the issue to `soc::running`.
6. Normal completion moves the issue to `soc::human-review` and posts a
   completion comment.
7. Agent failure moves the issue to `soc::failed` and posts a failure comment.

`tracker.active_states` controls GitLab polling discovery. Reconciliation also
recognizes `soc::claimed`, `soc::running`, and `soc::waiting-input` as
controlled in-progress lifecycle labels, so long-running agents are not
stopped after leaving the queue.

Known limitations:

- Persistent idempotency is local to one Symphony deployment. Multi-replica
  production deployments require a shared durable state store before enabling
  more than one active webhook receiver.
- If `tracker.state_path` is placed on ephemeral storage or deleted, replay
  protection and lifecycle comment suppression reset.
- GitLab project issue IID is used as the tracker issue ID for this phase.
- `/soc status`, `/soc retry`, and `/soc cancel` are parsed but return
  not-implemented responses.
- Branch creation, merge request creation, Cortex integration, IOC enrichment,
  responder actions, SOC UI, endpoint isolation, and automatic blocking are
  future phases.

Token boundary:

- GitLab comments and label mutations are performed only by the GitLab adapter.
- Codex turns are not given GitLab write credentials by the GitLab adapter.
- Local Codex app-server processes are launched with `GITLAB_API_TOKEN` and
  `GITLAB_WEBHOOK_SECRET` removed from their environment. If you add custom
  credentials or wrapper scripts, apply the same boundary explicitly.

Failure recovery:

- If a webhook is replayed after a successful delivery, Symphony returns a
  duplicate status from persistent state and performs no GitLab writeback.
- If a writeback exhausts retries, inspect the state file's `writebacks` entry
  for the operation, fix the GitLab permission or availability issue, and use a
  new operator comment to request a fresh run when appropriate.
- Do not manually edit the state file while Symphony is running. Stop the
  service first if emergency state repair is required.

Official GitLab references:

- Project access tokens: https://docs.gitlab.com/user/project/settings/project_access_tokens/
- Project access token API and rotation: https://docs.gitlab.com/api/project_access_tokens/
- Project webhooks: https://docs.gitlab.com/user/project/integrations/webhooks/
- Project webhooks API: https://docs.gitlab.com/api/project_webhooks/

The Spec Kit quickstart for this phase is available at
[`../specs/001-gitlab-control-plane/quickstart.md`](../specs/001-gitlab-control-plane/quickstart.md).
Live validation against a disposable GitLab staging project is tracked in
[`../specs/001-gitlab-control-plane/live-staging-validation.md`](../specs/001-gitlab-control-plane/live-staging-validation.md).
That checklist includes a Stage 3.5 mode that executes a real authenticated
local `codex app-server`, verifies that GitLab secrets are absent from the
child process, and distinguishes deterministic CLI startup failure from a
model-turn failure. The generated staging workflow explicitly sets
`codex.approval_policy: never` for app-server version compatibility.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
