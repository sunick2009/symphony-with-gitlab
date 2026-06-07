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
  command: codex app-server
  health_check_command: codex whoami
  approval_policy:
    reject:
      sandbox_approval: true
      rules: true
      mcp_elicitations: true
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
    for _EV in output/evidence/phase-*.md; do
      [ -f "$_EV" ] || continue
      _FN=$(basename "$_EV" .md)
      _FP="agent-results/issue-${_IID}/$(date -u +%Y%m%dT%H%M%SZ)/${_FN}.md"
      _FE=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$_FP")
      python3 -c "import json,base64,sys; d={'branch':sys.argv[1],'start_branch':'main','commit_message':'agent evidence','content':base64.b64encode(open(sys.argv[2],'rb').read()).decode(),'encoding':'base64'}; open('/tmp/_ev.json','w').write(json.dumps(d))" "agent-results/issue-${_IID}" "$_EV"
      curl -sf -X POST -H "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" -H "Content-Type: application/json" -d @/tmp/_ev.json "${_API}/repository/files/${_FE}" > /dev/null 2>&1 && echo "[evidence] pushed ${_FN}" || true
    done
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
