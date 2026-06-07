---
tracker:
  kind: gitlab
  endpoint: $GITLAB_ENDPOINT
  api_key: $GITLAB_API_TOKEN
  project_slug: $GITLAB_PROJECT_SLUG
  webhook_secret: $GITLAB_WEBHOOK_SECRET
  state_path: /var/lib/symphony/gitlab-control-plane-state.json
  writeback_max_attempts: 3
  writeback_base_backoff_ms: 250
  active_states: ["soc::queued"]
  terminal_states: ["soc::done", "soc::failed"]

polling:
  interval_ms: 5000

workspace:
  root: ~/symphony-workspaces

agent:
  max_concurrent_agents: 4
  max_turns: 20

codex:
  command: codex app-server
  health_check_command: codex whoami
  approval_policy:
    reject:
      sandbox_approval: true
      rules: true
      mcp_elicitations: true
  thread_sandbox: workspace-write

hooks:
  timeout_ms: 120000
  after_create: |
    # Clone the target repo and prepare workspace
    # Replace with your actual repo URL:
    # git clone --depth 1 "$SOURCE_REPO_URL" .
    mkdir -p output/artifacts
  after_run: |
    set -euo pipefail
    # Write result-posting script to temp file to avoid quoting issues
    _TMPPY=$(mktemp /tmp/symphony-post-results-XXXXXX.py)
    trap 'rm -f "$_TMPPY"' EXIT
    cat > "$_TMPPY" << 'PYEOF'
import sys, json, os, urllib.request, urllib.parse, base64

iid  = os.path.basename(os.getcwd()).lstrip('_')
ts   = sys.argv[1] if len(sys.argv) > 1 else 'results'

endpoint    = os.environ['GITLAB_ENDPOINT'].rstrip('/')
slug        = os.environ['GITLAB_PROJECT_SLUG']
token       = os.environ['GITLAB_API_TOKEN']
api         = f"{endpoint}/api/v4/projects/{urllib.parse.quote(slug, safe='')}"
project_url = f"{endpoint}/{slug}"

INLINE_MAX = 3_500    # chars — post directly as comment
BRANCH_MAX = 10 * 1024 * 1024  # 10 MB — push via Files API; beyond this note LFS

def post_note(body):
    data = json.dumps({'body': body}).encode()
    req  = urllib.request.Request(f"{api}/issues/{iid}/notes", data=data, method='POST',
           headers={'PRIVATE-TOKEN': token, 'Content-Type': 'application/json'})
    urllib.request.urlopen(req)

def push_file(repo_path, local_path, branch, start_branch='main'):
    """Upload a file to GitLab via the repository Files API."""
    content      = base64.b64encode(open(local_path, 'rb').read()).decode()
    encoded_path = urllib.parse.quote(repo_path, safe='')
    payload = {
        'branch': branch, 'start_branch': start_branch,
        'commit_message': f'agent: results for issue #{iid}',
        'content': content, 'encoding': 'base64',
    }
    req = urllib.request.Request(
        f"{api}/repository/files/{encoded_path}",
        data=json.dumps(payload).encode(), method='POST',
        headers={'PRIVATE-TOKEN': token, 'Content-Type': 'application/json'})
    try:
        urllib.request.urlopen(req)
        return True
    except urllib.error.HTTPError as e:
        print(f"push_file failed {repo_path}: {e.code} {e.read()[:200]}", file=sys.stderr)
        return False

# ── 1. Determine what output was produced ──────────────────────────────────
summary_path = 'output/summary.md'
report_path  = 'output/full-report.md'

if not os.path.exists(summary_path):
    print("No output/summary.md found — skipping result post")
    sys.exit(0)

summary = open(summary_path).read()
branch  = f"agent-results/issue-{iid}/{ts}"

# ── 2. Tier 1: small — inline comment ─────────────────────────────────────
if len(summary) <= INLINE_MAX:
    post_note(f"## Agent 執行結果\n\n{summary}")
    print(f"[result] posted inline comment ({len(summary)} chars)")

# ── 3. Tier 2: medium / large — push to branch, link in comment ───────────
else:
    report_file = report_path if os.path.exists(report_path) else summary_path
    file_key    = f"agent-results/issue-{iid}/{ts}/report.md"

    ok = push_file(file_key, report_file, branch)
    if ok:
        results_url = f"{project_url}/-/blob/{branch}/{file_key}"
        preview     = summary[:800] + ('\n\n_(truncated — see full report)_' if len(summary) > 800 else '')
        body = (f"## Agent 執行結果\n\n"
                f"結果較長，已推送至分支 `{branch}`。\n\n"
                f"[查看完整報告]({results_url})\n\n"
                f"### 摘要預覽\n\n{preview}")
        post_note(body)
        print(f"[result] branch report: {results_url}")
    else:
        # Fallback: post summary as-is even if large
        post_note(f"## Agent 執行結果\n\n{summary[:6000]}\n\n_(output truncated)_")

# ── 4. Artifacts ───────────────────────────────────────────────────────────
artifacts_dir = 'output/artifacts'
if os.path.isdir(artifacts_dir):
    for fname in sorted(os.listdir(artifacts_dir)):
        fpath = os.path.join(artifacts_dir, fname)
        fsize = os.path.getsize(fpath)
        repo_path = f"agent-results/issue-{iid}/{ts}/artifacts/{fname}"

        if fsize <= BRANCH_MAX:
            ok = push_file(repo_path, fpath, branch)
            if ok:
                artifact_url = f"{project_url}/-/blob/{branch}/{repo_path}"
                print(f"[artifact] pushed {fname} ({fsize:,} bytes): {artifact_url}")
        else:
            # > 10 MB: recommend LFS — cannot push via Files API
            post_note(
                f"Artifact `{fname}` ({fsize:,} bytes) 超過 10 MB 上限。\n"
                f"建議在目標 repo 設定 Git LFS (`git lfs track '{fname}'`)，"
                f"再由 agent 在 workspace 中以 `git lfs push` 方式推送。"
            )
            print(f"[artifact] {fname} too large ({fsize:,} bytes) — skipped, LFS needed")
PYEOF
    _TS=$(date -u +%Y%m%dT%H%M%SZ)
    python3 "$_TMPPY" "$_TS"

observability:
  dashboard_enabled: true
  refresh_ms: 2000

server:
  port: 8080
---
你是一個在 GitLab 上自主執行任務的 agent。

## 任務資訊

Issue: {{ issue.identifier }}
標題: {{ issue.title }}
描述:
{{ issue.description }}

## 工作指示

1. 仔細閱讀 issue 的要求，執行所有任務。
2. 在工作目錄的 `output/` 資料夾儲存執行結果：
   - `output/summary.md`：簡潔的摘要（500 字以內），包含執行了什麼、結果為何、狀態（completed / partial / blocked）。
   - `output/full-report.md`：完整的詳細輸出（如果摘要不足以說明）。
   - `output/artifacts/`：任何生成的檔案（程式碼、資料、圖片等）。
3. 不要主動呼叫外部服務，除非 issue 明確要求。
4. 如果遇到無法解決的外部阻礙（缺少憑證、服務無法連線），在 `output/summary.md` 的 **Status** 區塊清楚說明。
5. 完成後不要嘗試 push 或建立 PR，Symphony 的 hooks 會處理結果回報。

## output/summary.md 格式

```
## 摘要

[簡述執行了什麼]

## 結果

[主要輸出、發現或數據]

## 狀態

completed | partial | blocked

[如果 blocked：需要什麼才能繼續]
```
