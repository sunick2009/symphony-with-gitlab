---
# =============================================================================
# Symphony GitLab multi-phase workflow (plan-first-then-execute).
#
# Flow: /agent run -> planning turn writes output/workpad.md -> one phase per
# execution turn, each writing output/evidence/phase-N.md, updating a single
# GitLab workpad comment, and committing the evidence to the agent-results
# branch -> output/.state/completed -> soc::human-review.
#
# Hooks fire as: before_run -> (before_turn -> turn -> after_turn) * N -> after_run.
# before_turn/after_turn run once per Codex turn (see specs/004-per-turn-hooks).
#
# Invariants proven necessary by live e2e — DO NOT change without re-testing:
#   1. active_states MUST include soc::running. The agent works while the issue
#      is soc::running; if it is not "active", the per-turn continuation stops
#      after planning and no phase runs. Poller claim/running guards stop any
#      double-dispatch, so this is safe.
#   2. The after_turn evidence regex is anchored to the checklist bullet
#      (^- [x] Phase N). A loose [x].*?phase(\d+) matches prose mentioning both
#      tokens and falsely marks phases done.
#   3. after_turn moves the issue to soc::human-review only when
#      output/.state/completed exists, so the loop stops as soon as work is done
#      instead of burning empty turns up to max_turns.
#   4. The agent process has NO GitLab token (stripped at the boundary); every
#      GitLab mutation here runs in hooks, which carry adapter credentials.
#   5. This prompt is Chinese (multibyte UTF-8). Symphony reads it with
#      Workflow.split_front_matter, which splits on \r\n|\r|\n — never ~r/\R/,
#      which would corrupt the NEL byte 0x85 inside characters like 先 (E5 85 88).
#   6. after_turn pushes ALL phase evidence in ONE atomic /repository/commits
#      call (not one commit per file), skips files unchanged on the branch, and
#      truncates anything over EVIDENCE_MAX_BYTES (default 1 MiB). A failed push
#      is surfaced to stderr and aborts the hook with exit 1 BEFORE the
#      completion transition, so the issue stays active and the push is retried
#      next turn — evidence must land on the branch before work is declared done.
# =============================================================================
tracker:
  kind: gitlab
  endpoint: $GITLAB_ENDPOINT
  api_key: $GITLAB_API_TOKEN
  project_slug: $GITLAB_PROJECT_SLUG
  webhook_secret: $GITLAB_WEBHOOK_SECRET
  state_path: /var/lib/symphony/gitlab-control-plane-state.json
  writeback_max_attempts: 3
  writeback_base_backoff_ms: 250
  # soc::running must be active so the per-turn continuation keeps iterating
  # phases while the agent works; the run_blocking/claim guards prevent the
  # poller from re-dispatching an issue that already has a live agent.
  active_states: ["soc::queued", "soc::running"]
  terminal_states: ["soc::done", "soc::failed"]

polling:
  interval_ms: 5000

workspace:
  root: ~/symphony-workspaces

agent:
  max_concurrent_agents: 4
  max_turns: 20

codex:
  command: codex --config 'model="gpt-5.1-codex-mini"' --config model_reasoning_effort=medium app-server
  # `codex whoami` needs a TTY and exits 1 headless ("stdin is not a terminal"),
  # which would fail the pre-flight check and block every dispatch in
  # background/CI/docker. `codex login status` verifies auth tty-free (rc=0).
  health_check_command: codex login status
  # codex 0.135 app-server takes approval_policy as an enum
  # (untrusted | on-failure | on-request | granular | never); the old nested
  # `reject:` map is rejected with JSON-RPC -32600 and the agent fails on turn 0.
  # `never` = run fully headless, auto-deny every approval prompt (the intent of
  # the previous reject-everything map).
  approval_policy: never
  thread_sandbox: workspace-write

hooks:
  timeout_ms: 300000
  after_create: |
    mkdir -p output/.state output/evidence output/artifacts
  # before_turn runs before EVERY turn: it injects the current workpad into
  # CONTEXT.md so each execution turn sees the latest plan/progress state.
  before_turn: |
    if [ -f output/workpad.md ]; then
      echo "=== SYMPHONY WORKPAD CONTEXT ===" > CONTEXT.md
      cat output/workpad.md >> CONTEXT.md
      echo "" >> CONTEXT.md
      echo "=== EXECUTION MODE ===" >> CONTEXT.md
      echo "Read the workpad above. Find the first unchecked Phase and execute it." >> CONTEXT.md
      echo "[before_turn] injected workpad ($(wc -l < output/workpad.md) lines) into CONTEXT.md"
    else
      echo "[before_turn] no workpad yet — planning mode"
    fi
  # after_turn runs after EVERY turn: it validates evidence and syncs the workpad
  # to GitLab immediately, so the plan appears after turn 1 (planning) and each
  # phase's progress appears as soon as that phase completes.
  after_turn: |
    [ -f output/workpad.md ] || exit 0
    _IID="${PWD##*_}"
    _ENC=$(python3 -c "import urllib.parse,os; print(urllib.parse.quote(os.environ['GITLAB_PROJECT_SLUG'],safe=''))")
    _API="${GITLAB_ENDPOINT%/}/api/v4/projects/${_ENC}"
    python3 -c "import re,os,sys; wp=open('output/workpad.md').read(); phases=re.findall(r'(?m)^\s*-\s*\[x\]\s*[Pp]hase\s*(\d+)',wp); [sys.exit(1) or print(f'FAIL: Phase {n} done without evidence',file=sys.stderr) for n in phases if not os.path.exists(f'output/evidence/phase-{n}.md') or os.path.getsize(f'output/evidence/phase-{n}.md')<20]" || exit 1
    python3 -c "import json; body=open('output/workpad.md').read(); open('/tmp/_wb.json','w').write(json.dumps({'body':body}))"
    if [ -f output/.state/workpad_comment_id ]; then
      _NID=$(cat output/.state/workpad_comment_id)
      curl -sf -X PUT -H "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" -H "Content-Type: application/json" -d @/tmp/_wb.json "${_API}/issues/${_IID}/notes/${_NID}" > /dev/null && echo "[workpad] updated comment #${_NID}"
    else
      _RESP=$(curl -sf -X POST -H "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" -H "Content-Type: application/json" -d @/tmp/_wb.json "${_API}/issues/${_IID}/notes")
      python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$_RESP" > output/.state/workpad_comment_id
      echo "[workpad] created comment #$(cat output/.state/workpad_comment_id)"
    fi
    # Push all phase evidence to the agent-results branch as ONE atomic commit
    # (/repository/commits, not per-file), skipping unchanged files, truncating
    # oversized ones (EVIDENCE_MAX_BYTES, default 1 MiB), and SURFACING any API
    # failure (no silent || true). On failure the issue stays active so the push
    # is retried on the next turn before completion can proceed.
    python3 - "$_IID" <<'PUSH_EVIDENCE' || { echo "[after_turn] evidence push failed — issue stays active to retry next turn" >&2; exit 1; }
    import os, sys, json, base64, glob
    import urllib.request, urllib.parse, urllib.error

    iid = sys.argv[1]
    api = os.environ["GITLAB_ENDPOINT"].rstrip("/") + "/api/v4/projects/" + urllib.parse.quote(os.environ["GITLAB_PROJECT_SLUG"], safe="")
    token = os.environ["GITLAB_API_TOKEN"]
    branch = "agent-results/issue-" + iid
    max_bytes = int(os.environ.get("EVIDENCE_MAX_BYTES", "1048576"))
    q = lambda s: urllib.parse.quote(s, safe="")

    def call(method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(api + path, data=data, method=method,
            headers={"PRIVATE-TOKEN": token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def truncate(raw):
        if len(raw) <= max_bytes:
            return raw
        head, tail = int(max_bytes * 0.6), int(max_bytes * 0.3)
        note = ("\n\n... [truncated %d bytes; original %d > limit %d] ...\n\n"
                % (len(raw) - head - tail, len(raw), max_bytes)).encode()
        return raw[:head] + note + raw[-tail:]

    st, _ = call("GET", "/repository/branches/" + q(branch))
    branch_exists = st == 200

    actions = []
    for fp in sorted(glob.glob("output/evidence/phase-*.md")):
        with open(fp, "rb") as fh:
            content_b64 = base64.b64encode(truncate(fh.read())).decode()
        file_path = "agent-results/issue-%s/%s" % (iid, os.path.basename(fp))
        action = "create"
        if branch_exists:
            fst, fbody = call("GET", "/repository/files/%s?ref=%s" % (q(file_path), q(branch)))
            if fst == 200:
                if json.loads(fbody).get("content", "").strip() == content_b64.strip():
                    continue  # unchanged on the branch — skip to avoid empty commits
                action = "update"
            elif fst != 404:
                sys.stderr.write("[evidence] lookup failed status=%d path=%s body=%r\n" % (fst, file_path, fbody[:300]))
                sys.exit(2)
        actions.append({"action": action, "file_path": file_path,
                        "content": content_b64, "encoding": "base64"})

    if not actions:
        print("[evidence] nothing to push (no new or changed phase evidence)")
        sys.exit(0)

    payload = {"branch": branch, "actions": actions,
               "commit_message": "agent evidence for issue #%s (%d file(s))" % (iid, len(actions))}
    if not branch_exists:
        payload["start_branch"] = "main"

    st, body = call("POST", "/repository/commits", payload)
    if st not in (200, 201):
        sys.stderr.write("[evidence] PUSH FAILED status=%d branch=%s body=%r\n" % (st, branch, body[:500]))
        sys.exit(2)
    print("[evidence] committed %d file(s) to %s (status=%d)" % (len(actions), branch, st))
    PUSH_EVIDENCE
    # When the agent signals completion, move the issue to human-review so the
    # per-turn continuation stops immediately instead of burning empty turns.
    if [ -f output/.state/completed ]; then
      curl -sf -X PUT -H "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" "${_API}/issues/${_IID}?add_labels=soc::human-review&remove_labels=soc::running,soc::queued" > /dev/null && echo "[workpad] completed → soc::human-review"
    fi

observability:
  dashboard_enabled: true
  refresh_ms: 2000

server:
  port: 8080
---
你是一個在 GitLab 上執行多階段任務的自主 agent。

## 啟動流程

**首先**，檢查工作目錄是否存在 `CONTEXT.md`：
- 如果存在：你正處於**執行模式**，讀取它來了解當前進度
- 如果不存在：你正處於**規劃模式**，執行以下規劃流程

---

## 規劃模式（Planning）

任務資訊：
- Issue: {{ issue.identifier }}
- 標題: {{ issue.title }}
- 描述: {{ issue.description }}

**步驟：**
1. 分析 issue 的完整需求
2. 把工作拆分為 3-7 個可驗證的階段（Phase）
3. 為每個 Phase 定義明確的「完成標準」（什麼算是有效的 evidence）
4. 建立 `output/workpad.md`（格式如下）
5. **結束此次 turn**（不要開始執行，讓 Symphony 把計劃同步到 GitLab 後再繼續）

**output/workpad.md 格式：**

```markdown
## 工作台 (Workpad)

**Issue**: {{ issue.identifier }} — {{ issue.title }}
**建立時間**: [ISO timestamp]
**狀態**: planning

### 執行計劃

- [ ] Phase 1: [描述]
  - 完成標準: [具體的 evidence 要求，例如：命令輸出、檔案內容、測試通過]
- [ ] Phase 2: [描述]
  - 完成標準: [...]
...

### 進度日誌

| 時間 | 階段 | 狀態 | 摘要 |
|------|------|------|------|

### 備註

[任何重要的觀察或決策]
```

---

## 執行模式（Execution）

讀取 `CONTEXT.md`，找出第一個 `[ ]`（未完成）的 Phase。

**每個 Phase 的執行步驟：**

1. **執行工作**：完成該 Phase 描述的所有任務
2. **收集 evidence**：把實際的執行輸出存入 `output/evidence/phase-N.md`
   - evidence 必須是真實的命令輸出、程式碼、資料等
   - 不接受只寫「已完成」或「執行成功」的空洞陳述
3. **更新 workpad**：
   - 把 `[ ] Phase N` 改為 `[x] Phase N`
   - 在進度日誌新增一行（含 timestamp）
   - 如果 Phase 失敗或被阻擋：寫入原因，不要假裝完成
4. **結束此次 turn**（讓 Symphony 同步進度，下一個 turn 繼續下一個 Phase）

**所有 Phase 完成後：**

1. 把 workpad 的狀態改為 `completed`
2. 新增一個摘要區塊 `### 最終結果` 說明整體成果
3. 建立 `output/.state/completed`（空檔案即可）
4. 結束最後一個 turn

---

## 嚴格規則（不得違反）

1. **禁止跳步驟**：必須按 Phase 順序執行，不能跳過任何 Phase
2. **evidence 是必須的**：勾選 `[x]` 之前，`output/evidence/phase-N.md` 必須存在且包含真實輸出（> 20 bytes）。Symphony 的 hook 會驗證這一點，缺少 evidence 會導致 hook 失敗
3. **一個 turn 只執行一個 Phase**：完成一個 Phase 後就結束 turn，讓 Symphony 同步進度
4. **規劃模式只規劃**：規劃模式中不執行任何 Phase 的實際工作
5. **blocked 要明確回報**：遇到無法解決的外部阻礙（缺少憑證、服務不可用），在 workpad 記錄並把狀態改為 `blocked`，結束 turn
