# MVP-0 Devcontainer Runbook

A practical, end-to-end runbook for starting the GitLab-backed agent
orchestration layer inside a devcontainer and validating the **staging**
workflow:

```text
fresh devcontainer
  -> build
  -> env config
  -> Codex or fake-runner check
  -> start Symphony HTTP server
  -> expose webhook
  -> configure GitLab staging project
  -> /agent run
  -> observe workpad / evidence / MR / CI / audit timeline
  -> cleanup
```

> [!WARNING]
> This is **MVP-0, staging-only**. Symphony Elixir is prototype software. The
> control plane is single-node, file-backed, and validated against disposable
> GitLab staging projects only. Do **not** point it at a production GitLab
> project, and do **not** use temporary tunnels as production endpoints. See
> [Limitations](#13-mvp-0-limitations).

Authoritative companions to this runbook:

- [`elixir/README.md`](../elixir/README.md) — full configuration reference.
- [`elixir/WORKFLOW.gitlab.md`](../elixir/WORKFLOW.gitlab.md) — canonical
  multi-phase GitLab workflow template (and its invariant comments).
- [`AGENTS.md`](../AGENTS.md) — multi-phase execution model and hook timing.
- [`AGENT_MEMORY.md`](../AGENT_MEMORY.md) — stage history and known limits.
- [`specs/001-gitlab-control-plane/quickstart.md`](../specs/001-gitlab-control-plane/quickstart.md)
  — the original control-plane quickstart.

---

## 1. Devcontainer prerequisites

The repo ships a devcontainer at [`.devcontainer/`](../.devcontainer/).

> [!NOTE]
> `.devcontainer/` is currently **git-ignored** (see [`.gitignore`](../.gitignore):
> "Local editor container experiment. Review before promoting to supported
> setup."). Treat it as a developer convenience, not a supported deployment
> artifact. The supported deployment artifact is the root
> [`Dockerfile`](../Dockerfile) + [`docker-compose.yml`](../docker-compose.yml)
> (see [`elixir/README.md` → Docker deployment](../elixir/README.md#docker-deployment)).

The devcontainer is built `FROM ghcr.io/openai/codex-universal:latest`
(`.devcontainer/Dockerfile`) and provisions, via `post-create.sh`:

- the `codex`, `claude`, and `gemini` CLIs;
- Node.js 22 + pnpm + TypeScript.

It bind-mounts your host `~/.codex`, `~/.claude`, and `~/.ssh` into the
container so existing Codex auth is reused.

### Host requirements

- Docker (the devcontainer enables docker-in-docker).
- VS Code Dev Containers extension (or any devcontainer-compatible runner).
- A host `~/.codex` directory if you intend to use the **real Codex runner**
  (so an authenticated token is mounted in). Not needed for the
  [fake-runner path](#4-validation-path-a-fake-runner-no-codex-login).

---

## 2. Required tools (verify inside the container)

The codex-universal base + post-create steps provide everything. Confirm:

```bash
mise --version        # toolchain manager
codex --version       # Codex CLI (real-runner path only)
git --version
curl --version
python3 --version     # used by the WORKFLOW.gitlab.md after_turn hook
lt --version          # localtunnel, for exposing the webhook (npx alt below)
```

Elixir/Erlang are **not** preinstalled globally; `mise` provides them, pinned by
[`elixir/mise.toml`](../elixir/mise.toml) to Erlang 28 / Elixir 1.19.5-otp-28.
Verify after `mise install` (step 5):

```bash
cd elixir && mise exec -- elixir --version
# Erlang/OTP 28 ... / Elixir 1.19.5 (compiled with Erlang/OTP 28)
```

If `lt` is not on PATH, use `npx localtunnel --port 8080` instead.

---

## 3. Codex authentication (read before choosing a path)

There are two validation paths. **Pick one.**

| | Codex login required? | What it proves |
|---|---|---|
| **A. Fake-runner / helper** | **No** | Control plane: webhook → queue → lifecycle labels → comments → audit timeline, with no model cost. |
| **B. Real Codex runner** | **Yes** | The full loop including real Codex turns, workpad, evidence push, MR/CI. |

Auth rules (apply to both paths where relevant):

- The **fake-runner / helper path does not require Codex login.**
- The **real Codex runner requires `codex` installed and authenticated inside
  the devcontainer.** Verify tty-free with:
  ```bash
  codex login status   # rc=0 and "Logged in using ChatGPT" when authenticated
  ```
  Do **not** use `codex whoami` for health checks — it needs a TTY and exits 1
  headless, which would block every dispatch. The shipped workflow uses
  `health_check_command: codex login status` for exactly this reason.
- **Recommend an explicit `CODEX_HOME`.** Set it so auth lives in a known,
  non-repo, non-ephemeral location:
  ```bash
  export CODEX_HOME=/root/.codex   # matches the devcontainer bind-mount
  ```
- **Never commit Codex auth files** (`~/.codex/auth.json`, tokens). They are
  outside the repo and the devcontainer mounts them read-only; keep it that way.
- **Never expose `GITLAB_API_TOKEN` or `GITLAB_WEBHOOK_SECRET` to the Codex
  agent process.** Symphony strips both from the Codex child environment at the
  worker boundary. If you add wrapper scripts or custom credentials, preserve
  that boundary explicitly. GitLab mutation is adapter-owned; the agent never
  receives a GitLab write token and credentialed agent-owned `git push` is
  disallowed. (The `after_turn` hook in `WORKFLOW.gitlab.md` performs GitLab
  writes — it runs in the **hook** context with adapter credentials, not inside
  the Codex agent process.)

---

## 4. Validation path A: fake-runner (no Codex login)

Use this to validate the control plane without model cost or Codex auth. The
"fake runner" is any `codex.command` that speaks the app-server protocol enough
to start/stop a session — in practice the repo validates the control plane via
the targeted test suite, which stubs the runner. For a live control-plane-only
smoke without real model turns:

1. Use a workflow whose `codex.command` points at a stub that exits cleanly, or
   keep the issue in a state where dispatch is observed but no model work is
   needed.
2. The repo's automated coverage already exercises this path deterministically:
   ```bash
   cd elixir
   mise exec -- mix test test/symphony_elixir/gitlab_test.exs \
                         test/symphony_elixir/gitlab_lifecycle_test.exs
   ```
   These verify webhook parsing, queueing, lifecycle label transitions,
   adapter-owned comments, idempotency, and the token boundary
   (`GITLAB_API_TOKEN=unset` in the agent trace) without any Codex login.

> The fake-runner path is the recommended first validation: it confirms the
> GitLab control plane end-to-end before you spend real Codex budget.

---

## 5. Build and configure (real-runner path)

```bash
cd elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
```

`mix setup` fetches deps; `mix build` compiles and produces the `bin/symphony`
escript. (`mix build` is the repo alias; the upstream `mix escript.build` is
equivalent for the container image.)

### Environment variables

| Var | Required | Purpose |
|---|---|---|
| `GITLAB_API_TOKEN` | yes (live) | GitLab API token, `api` scope. Adapter-only. |
| `GITLAB_WEBHOOK_SECRET` | yes (webhook) | Shared secret validated as `X-Gitlab-Token`. |
| `GITLAB_ENDPOINT` | optional | Defaults to `https://gitlab.com`. |
| `GITLAB_PROJECT_SLUG` | yes | e.g. `group/disposable-staging-project`. |
| `CODEX_HOME` | recommended | Codex auth location (e.g. `/root/.codex`). |
| `EVIDENCE_MAX_BYTES` | optional | Per-evidence-file truncation cap (default 1 MiB). |

```bash
export GITLAB_API_TOKEN=...            # api scope; NOT write_repository
export GITLAB_WEBHOOK_SECRET=...       # rotate independently of the API token
export GITLAB_ENDPOINT=https://gitlab.com
export GITLAB_PROJECT_SLUG=group/disposable-staging-project
export CODEX_HOME=/root/.codex
```

> Store secrets in your shell/session only. Never commit them, never echo them
> into tracked files, never pass them to the agent process.

---

## 6. GitLab disposable staging project setup

1. Create a **disposable** GitLab project you can delete afterward. Never use a
   production project.
2. Create a token with the **`api`** scope (project or group access token, or a
   project bot token with the minimum role that can update issues). `read_api`
   is read-only and insufficient. Do **not** grant `write_repository`,
   registry, runner, or AI scopes.
3. Create the lifecycle labels:

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

4. (For evidence push + MR) ensure the project has a default `main` branch —
   the `after_turn` hook commits evidence to `agent-results/issue-<iid>` based
   off `main`.

---

## 7. WORKFLOW.gitlab.md setup

Use [`elixir/WORKFLOW.gitlab.md`](../elixir/WORKFLOW.gitlab.md) as-is for the
multi-phase, plan-first-then-execute flow. It already encodes the invariants
proven necessary by live e2e (see its header comments and
[AGENTS.md](../AGENTS.md)). Key points you must preserve:

- `tracker.active_states` **must** include `soc::running` (otherwise the
  per-turn loop stops after the planning turn).
- `tracker.state_path` defaults to `/var/lib/symphony/gitlab-control-plane-state.json`
  — a **durable path outside the repo and outside workspace cleanup**.
- For **live MR creation** (Stage 4), the workflow/tracker config must set both
  `stage4_live_mutation: true` and list your slug in
  `stage4_allowed_project_slugs`. Left at defaults, Symphony stays in dry-run
  (manifest validation + planning, no repository mutation). Only ever list a
  disposable staging slug here.
- `codex.health_check_command: codex login status` (tty-free auth pre-flight).
- `codex.approval_policy: never` (headless; codex ≥ 0.135 rejects the old
  nested `reject:` map).

The workflow reads `GITLAB_ENDPOINT`, `GITLAB_API_TOKEN`, `GITLAB_PROJECT_SLUG`,
and `GITLAB_WEBHOOK_SECRET` from the environment (step 5).

---

## 8. Start Symphony with the HTTP server

```bash
cd elixir
mise exec -- ./bin/symphony /path/to/WORKFLOW.gitlab.md --port 8080
```

- `--port` enables the Phoenix observability dashboard, JSON API
  (`/api/v1/*`), and the GitLab webhook receiver at
  `POST /api/v1/gitlab/webhook`.
- `--logs-root <dir>` redirects logs (default `./log`).
- Without a path argument, Symphony defaults to `./WORKFLOW.md`.

You can point `--port` at any free port; `8080` is used throughout this runbook.

---

## 9. Expose the webhook

GitLab.com must reach the container's `:8080`. Options, in order of preference:

1. **Forwarded port (devcontainer/VS Code):** forward `8080`; if your editor
   gives a public HTTPS URL, use it. Simplest when available.
2. **localtunnel (disposable staging only):**
   ```bash
   lt --port 8080
   # or: npx localtunnel --port 8080
   ```
   Use the printed `https://<sub>.loca.lt` URL.

> Tunnels are acceptable for disposable staging only — never as a production
> endpoint. TLS should terminate at a stable endpoint for any real use.

### Configure the GitLab project webhook

- **URL:** `https://<your-host>/api/v1/gitlab/webhook`
- **Secret token:** the exact `GITLAB_WEBHOOK_SECRET` value.
- **Triggers:** enable **Comments / note events** (issue comment events drive
  dispatch). Issue events may be enabled but do not dispatch in this phase.

---

## 10. Trigger `/agent run`

1. Open an issue in the staging project.
2. Add a comment with the command **at the start of a line**:
   ```text
   /agent run
   ```
   (`/soc run` is a supported legacy alias.)

---

## 11. Expected observable timeline

After `/agent run`, expect:

1. **Ack + label:** webhook secret validated → issue gets `soc::queued` and an
   acknowledgement comment.
2. **Dispatch:** poller discovers the queued issue → moves it to `soc::running`.
3. **Plan (turn 1):** Codex writes `output/workpad.md`; the `after_turn` hook
   creates a single **workpad comment** in the issue (the plan appears *before*
   execution).
4. **Execution (one phase per turn):** each phase writes
   `output/evidence/phase-N.md`; `after_turn` validates evidence
   (`^- [x] Phase N` requires a matching, >20-byte evidence file), PUT-updates
   the same workpad comment, and pushes all phase evidence as **one atomic
   commit** to branch `agent-results/issue-<iid>`.
5. **Completion:** agent writes `output/.state/completed` → `after_turn` moves
   the issue to `soc::human-review`; the loop stops cleanly (no empty turns).
6. **(Stage 4, if live MR enabled):** adapter-owned branch
   `soc/issue-<iid>/<run-fingerprint>`, commit with provenance marker, MR
   titled `Issue #<iid>: <title>`, MR-link writeback comment.
7. **(Stage 4 CI):** CI reconciliation polls the newest MR pipeline and posts an
   idempotent CI status comment (`ci-pending|running|success|failure|unknown`);
   success and failure both leave the issue at `soc::human-review`.
8. **Failure path:** runner/agent failure → `soc::failed` + failure comment.

### Inspect the audit timeline

```bash
cd elixir
mise exec -- mix gitlab.timeline --issue <iid>
mise exec -- mix gitlab.timeline --trace <trace_id>
```

These read the **local** append-only JSONL audit log derived from
`tracker.state_path` (e.g.
`/var/lib/symphony/gitlab-control-plane-state.audit.jsonl`). They are local
operator tools, not a centralized backend. Audit records omit tokens, secrets,
raw prompts/bodies, and full artifact content.

---

## 12. Local smoke test (minimal, no GitLab required)

Run these inside `elixir/` to confirm the deployment is sound before involving a
live GitLab project. Each maps to a goal-level assertion:

| Check | Command / verification |
|---|---|
| App boots / compiles | `mise exec -- mix build` (produces `bin/symphony`, rc 0) |
| HTTP server listens | start with `--port 8080`, then `curl -s localhost:8080/api/v1/state` returns JSON |
| GitLab webhook route exists | route registered at `elixir/lib/symphony_elixir_web/router.ex` (`POST /api/v1/gitlab/webhook`); a bad-secret `curl -XPOST localhost:8080/api/v1/gitlab/webhook` is rejected |
| `/agent run` parsing | covered by `mise exec -- mix test test/symphony_elixir/gitlab_test.exs` |
| `mix gitlab.timeline` works | `mise exec -- mix gitlab.timeline --issue 42` (prints "No matching GitLab audit events" with an empty log) |
| State/audit paths outside repo | `tracker.state_path: /var/lib/symphony/...`; confirm with `git check-ignore -v <state_path>` is N/A (it is outside the repo) and that `*.gitlab-control-plane-state.json` is git-ignored |

Quick full local check:

```bash
cd elixir
mise exec -- mix format --check-formatted
mise exec -- mix test                 # passes regardless of seed / --max-cases
mise exec -- mix test --seed 0        # optional deterministic smoke check
mise exec -- mix specs.check
```

---

## 13. MVP-0 limitations

- Persistent state is **local file-backed, single-node**. Multi-node needs a
  shared/centralized store before enabling more than one webhook receiver.
- Staging-validated only; **not production-ready**.
- Tunnels are staging-only, not production endpoints.
- CI reconciliation is **polling-based** (newest relevant MR pipeline only).
- Audit observability is **local JSONL only**, not centralized/multi-node.
- Auto-merge is out of scope; CI success and failure both stop at
  `soc::human-review` for human decision.
- Out of scope by design: Cortex, IOC enrichment, responder actions, SOC UI,
  endpoint isolation, automatic blocking, production GitLab targeting,
  multi-node deployment, centralized observability/dashboards, and credentialed
  agent-owned `git push`.

---

## 14. Cleanup

In staging, cleanup is manual and should be done **with Symphony stopped**:

1. Stop Symphony (Ctrl-C) and the tunnel (`lt`/`npx`).
2. In the GitLab staging project:
   - close the disposable MR (if any);
   - delete the disposable branches `soc/issue-<iid>/*` and
     `agent-results/issue-<iid>`;
   - optionally delete the disposable project entirely.
3. Remove local state **only while Symphony is stopped**:
   ```bash
   rm -f /var/lib/symphony/gitlab-control-plane-state.json \
         /var/lib/symphony/gitlab-control-plane-state.audit.jsonl
   ```
   Losing this file does not expose secrets, but it resets webhook replay
   suppression and lifecycle-comment idempotency.
4. Clean workspaces: remove the per-issue dirs under `workspace.root`
   (default `~/symphony-workspaces`).
5. Rotate the staging `GITLAB_API_TOKEN` / `GITLAB_WEBHOOK_SECRET` if they were
   exposed (e.g. via a tunnel URL).

---

## 15. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Every dispatch fails the health check headless | You used `codex whoami` (needs a TTY). Use `codex login status`. |
| Agent fails on turn 0 with JSON-RPC `-32600` | `approval_policy` set to the old nested `reject:` map on codex ≥ 0.135. Use `approval_policy: never`. |
| Plan posts but no phases run | `soc::running` missing from `tracker.active_states`. Add it. |
| Non-ASCII (Chinese) prompt crashes at turn start | A prompt splitter used `~r/\R/` (matches NEL byte 0x85 mid-UTF-8). Symphony uses `~r/\r\n|\r|\n/`; keep any custom splitting line-terminator-only. |
| Webhook returns rejected / no dispatch | Secret mismatch — the GitLab webhook secret must equal `GITLAB_WEBHOOK_SECRET`; note events must be enabled; command must be at line start. |
| Duplicate `/agent run` does nothing | Expected: replayed webhooks and duplicate commands are suppressed via persistent state. |
| Live MR not created (only a plan) | Stage 4 dry-run: set `stage4_live_mutation: true` **and** list the slug in `stage4_allowed_project_slugs` (disposable only). |
| Writeback exhausted retries | Inspect the `writebacks` entry in the state file (Symphony stopped), fix the GitLab permission/availability issue, re-trigger with a fresh comment. |
| `403/404` on GitLab writes | Token lacks `api` scope or the project role can't update issues. Permission errors are surfaced without retry. |
| Evidence push fails, issue stays active | Intentional: the `after_turn` hook aborts before completion so the push retries next turn. Check stderr for the GitLab API error. |
| Full `mix test` shows many `stop_default_http_server` exits | Fixed in Stage 006: test `setup` now self-heals the shared app supervisor (`TestSupport.ensure_application_started!/0`). If you see this on an older checkout, that fix is missing — the suite there is order/load-sensitive; use `mix test --seed 0` or update `test/support/test_support.exs`. |

---

## Appendix A: graphify-out scope

`graphify-out/` is a **developer-analysis / generated artifact**. It is **not
runtime-required** by Symphony — the Elixir app, escript, and Docker image never
read it, and nothing in `lib/` references it.

What it is for: a committed knowledge-graph snapshot that lets coding agents
answer codebase questions via `graphify query` without regenerating the graph
(per the "graphify" section of [`AGENTS.md`](../AGENTS.md)).

Tracking decision (intentional, defined in [`.gitignore`](../.gitignore)):

- **Tracked:** `graphify-out/graph.json` (~2 MB) and
  `graphify-out/GRAPH_REPORT.md` (~76 KB) — the query/report snapshot.
- **Ignored:** everything else under `graphify-out/` — `graph.html`, all
  `.graphify_*` intermediates, `cache/`, dated run dirs, and transcripts.

Why `graph.json` stays tracked despite its size: it is the artifact agents query
against, and regenerating it requires the graphify tool (the semantic layer may
incur API cost). The trade-off is git churn — a `graphify update .` rewrites a
large fraction of the file. If that churn becomes a problem, the supported
options (out of scope for this runbook, owner decision) are to stop tracking
`graph.json` and regenerate on demand, or to store it via Git LFS. This runbook
does **not** change the current tracking and does **not** expand graphify.
</content>
