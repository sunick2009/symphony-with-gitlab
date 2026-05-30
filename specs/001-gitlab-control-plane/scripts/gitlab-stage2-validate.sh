#!/usr/bin/env bash
set -euo pipefail

readonly RUNTIME_DIR="${STAGE2_RUNTIME_DIR:-/tmp/symphony-stage2}"
readonly EVIDENCE_DIR="${STAGE2_EVIDENCE_DIR:-${RUNTIME_DIR}/evidence}"
readonly WORKFLOW_FILE="${STAGE2_WORKFLOW_FILE:-${RUNTIME_DIR}/WORKFLOW.stage2.md}"
readonly AGENT_TRACE="${SYMPHONY_STAGE2_AGENT_TRACE:-${RUNTIME_DIR}/agent-env.trace}"
readonly FAKE_CODEX="${RUNTIME_DIR}/fake-codex-stage2"
readonly DEFAULT_ENV_FILE="elixir/.env"

readonly LABELS=(
  "soc::queued"
  "soc::claimed"
  "soc::running"
  "soc::waiting-input"
  "soc::human-review"
  "soc::rework"
  "soc::failed"
  "soc::done"
)

usage() {
  cat <<'EOF'
Usage:
  gitlab-stage2-validate.sh preflight
  gitlab-stage2-validate.sh ensure-labels
  gitlab-stage2-validate.sh list-webhooks
  gitlab-stage2-validate.sh ensure-webhook
  gitlab-stage2-validate.sh write-workflow success|failure
  gitlab-stage2-validate.sh create-success-issue
  gitlab-stage2-validate.sh post-run success|failure|duplicate
  gitlab-stage2-validate.sh verify-duplicate
  gitlab-stage2-validate.sh poll success|failure
  gitlab-stage2-validate.sh notes success|failure
  gitlab-stage2-validate.sh token-boundary
  gitlab-stage2-validate.sh evidence-summary
  gitlab-stage2-validate.sh render-report
  gitlab-stage2-validate.sh assert-complete

Required environment, values must not be printed:
  GITLAB_ENDPOINT
  GITLAB_PROJECT_SLUG
  GITLAB_API_TOKEN
  STAGE2_CONFIRM_DISPOSABLE_PROJECT=yes

Optional:
  GITLAB_PROJECT_ID
  GITLAB_WEBHOOK_SECRET
  GITLAB_WEBHOOK_PUBLIC_URL
  STAGE2_ENV_FILE
  STAGE2_RUN_ID
  STAGE2_RUNTIME_DIR
  STAGE2_EVIDENCE_DIR
  STAGE2_WORKFLOW_FILE
  SYMPHONY_STAGE2_AGENT_TRACE
EOF
}

load_env_file() {
  local env_file="${STAGE2_ENV_FILE:-$DEFAULT_ENV_FILE}"

  if [ ! -f "$env_file" ]; then
    return 0
  fi

  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_base_env() {
  local missing=0
  for name in \
    GITLAB_ENDPOINT \
    GITLAB_PROJECT_SLUG \
    GITLAB_API_TOKEN
  do
    if [ -z "${!name:-}" ]; then
      echo "missing required environment variable: ${name}" >&2
      missing=1
    fi
  done

  if [ "${STAGE2_CONFIRM_DISPOSABLE_PROJECT:-}" != "yes" ]; then
    echo "STAGE2_CONFIRM_DISPOSABLE_PROJECT must be set to yes" >&2
    missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi
}

require_webhook_env() {
  local missing=0

  require_base_env

  for name in \
    GITLAB_WEBHOOK_SECRET \
    GITLAB_WEBHOOK_PUBLIC_URL
  do
    if [ -z "${!name:-}" ]; then
      echo "missing required environment variable: ${name}" >&2
      missing=1
    fi
  done

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi
}

require_tools() {
  require_command curl
  require_command jq
}

init_dirs() {
  mkdir -p "$RUNTIME_DIR" "$EVIDENCE_DIR" "${RUNTIME_DIR}/workspaces"
}

api_url() {
  local path="$1"
  printf '%s/api/v4/projects/%s%s' \
    "${GITLAB_ENDPOINT%/}" \
    "$(project_ref)" \
    "$path"
}

project_ref() {
  if [ -n "${GITLAB_PROJECT_ID:-}" ]; then
    printf '%s' "$GITLAB_PROJECT_ID"
  else
    jq -rn --arg value "$GITLAB_PROJECT_SLUG" '$value | @uri'
  fi
}

curl_json() {
  local method="$1"
  local path="$2"
  shift 2

  curl --fail --silent --show-error \
    --request "$method" \
    --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
    "$@" \
    "$(api_url "$path")"
}

print_safe_env() {
  for name in \
    GITLAB_ENDPOINT \
    GITLAB_PROJECT_ID \
    GITLAB_PROJECT_SLUG \
    GITLAB_API_TOKEN \
    GITLAB_WEBHOOK_SECRET \
    GITLAB_WEBHOOK_PUBLIC_URL \
    STAGE2_RUN_ID \
    STAGE2_CONFIRM_DISPOSABLE_PROJECT
  do
    if [ -n "${!name:-}" ]; then
      printf '%s=<set>\n' "$name"
    else
      printf '%s=<unset>\n' "$name"
    fi
  done
}

preflight() {
  require_base_env
  require_tools
  init_dirs

  print_safe_env | tee "${EVIDENCE_DIR}/preflight-env.txt"

  local project_json
  project_json="$(curl_json GET "")"
  printf '%s' "$project_json" >"${EVIDENCE_DIR}/project.json"

  local project_path
  project_path="$(printf '%s' "$project_json" | jq -r '.path_with_namespace')"

  if [ "$project_path" != "$GITLAB_PROJECT_SLUG" ]; then
    echo "project slug mismatch: API project does not match GITLAB_PROJECT_SLUG" >&2
    exit 1
  fi

  printf '%s' "$project_json" | jq '{id, path_with_namespace, web_url, visibility}'
}

ensure_labels() {
  require_base_env
  require_tools
  init_dirs

  : >"${EVIDENCE_DIR}/labels.jsonl"

  for label in "${LABELS[@]}"; do
    local response status body
    response="$(
      curl --silent --show-error \
        --write-out '\n%{http_code}' \
        --request POST \
        --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
        --data-urlencode "name=${label}" \
        --data-urlencode "color=#428BCA" \
        "$(api_url "/labels")"
    )"
    status="$(printf '%s' "$response" | tail -n 1)"
    body="$(printf '%s' "$response" | sed '$d')"

    case "$status" in
      200|201|409)
        printf '{"label":%s,"status":%s,"body":%s}\n' \
          "$(jq -Rn --arg v "$label" '$v')" \
          "$(jq -Rn --arg v "$status" '$v')" \
          "$(printf '%s' "$body" | jq -c '.')" \
          | tee -a "${EVIDENCE_DIR}/labels.jsonl"
        ;;
      *)
        echo "label setup failed for ${label} with HTTP ${status}" >&2
        printf '%s\n' "$body" >&2
        exit 1
        ;;
    esac
  done
}

sanitize_webhooks() {
  jq '[.[] | {
    id,
    url,
    note_events,
    issues_events,
    enable_ssl_verification,
    push_events,
    merge_requests_events,
    token_present,
    signing_token_present
  }]'
}

list_webhooks() {
  require_webhook_env
  require_tools
  init_dirs

  curl_json GET "/hooks" >"${EVIDENCE_DIR}/webhooks-raw.json"
  sanitize_webhooks <"${EVIDENCE_DIR}/webhooks-raw.json" >"${EVIDENCE_DIR}/webhooks.json"
  cat "${EVIDENCE_DIR}/webhooks.json"
}

matching_webhook() {
  local source_file="$1"

  jq --arg url "$GITLAB_WEBHOOK_PUBLIC_URL" \
    '[.[] | select(.url == $url)] | first // empty' \
    "$source_file"
}

sanitize_webhook_file() {
  local source_file="$1"
  local target_file="$2"

  jq '{
    id,
    url,
    note_events,
    issues_events,
    enable_ssl_verification,
    push_events,
    merge_requests_events,
    token_present,
    signing_token_present
  }' "$source_file" >"$target_file"
}

write_webhook_settings() {
  local method="$1"
  local path="$2"
  local raw_file="$3"

  curl_json "$method" "$path" \
    --data-urlencode "url=${GITLAB_WEBHOOK_PUBLIC_URL}" \
    --data-urlencode "token=${GITLAB_WEBHOOK_SECRET}" \
    --data-urlencode "note_events=true" \
    --data-urlencode "issues_events=true" \
    --data-urlencode "enable_ssl_verification=true" \
    --data-urlencode "push_events=false" \
    --data-urlencode "merge_requests_events=false" \
    >"$raw_file"
}

ensure_webhook() {
  require_webhook_env
  require_tools
  init_dirs

  list_webhooks >/dev/null

  local existing_hook
  existing_hook="$(matching_webhook "${EVIDENCE_DIR}/webhooks.json")"

  if [ -n "$existing_hook" ]; then
    local existing_hook_id
    existing_hook_id="$(printf '%s' "$existing_hook" | jq -r '.id')"

    write_webhook_settings PUT "/hooks/${existing_hook_id}" "${EVIDENCE_DIR}/webhook-updated-raw.json"
    sanitize_webhook_file "${EVIDENCE_DIR}/webhook-updated-raw.json" "${EVIDENCE_DIR}/webhook.json"
    cat "${EVIDENCE_DIR}/webhook.json"
    return 0
  fi

  write_webhook_settings POST "/hooks" "${EVIDENCE_DIR}/webhook-created-raw.json"
  sanitize_webhook_file "${EVIDENCE_DIR}/webhook-created-raw.json" "${EVIDENCE_DIR}/webhook.json"

  cat "${EVIDENCE_DIR}/webhook.json"
}

write_workflow() {
  local mode="${1:-}"
  if [ "$mode" != "success" ] && [ "$mode" != "failure" ]; then
    echo "write-workflow requires success or failure" >&2
    exit 1
  fi

  require_webhook_env
  require_tools
  init_dirs

  local endpoint_json project_slug_json
  endpoint_json="$(jq -Rn --arg value "$GITLAB_ENDPOINT" '$value')"
  project_slug_json="$(jq -Rn --arg value "$GITLAB_PROJECT_SLUG" '$value')"

  if [ "$mode" = "success" ]; then
    cat >"$FAKE_CODEX" <<'SH'
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
  else
    cat >"$FAKE_CODEX" <<'SH'
#!/bin/sh
trace_file="${SYMPHONY_STAGE2_AGENT_TRACE:-/tmp/symphony-stage2/agent-env.trace}"
{
  printf 'GITLAB_API_TOKEN=%s\n' "${GITLAB_API_TOKEN-unset}"
  printf 'GITLAB_WEBHOOK_SECRET=%s\n' "${GITLAB_WEBHOOK_SECRET-unset}"
} >> "$trace_file"
exit 42
SH
  fi

  chmod 755 "$FAKE_CODEX"

  cat >"$WORKFLOW_FILE" <<EOF
---
codex:
  command: ${FAKE_CODEX} app-server

tracker:
  kind: gitlab
  endpoint: ${endpoint_json}
  api_key: \$GITLAB_API_TOKEN
  project_slug: ${project_slug_json}
  webhook_secret: \$GITLAB_WEBHOOK_SECRET
  active_states: ["soc::queued"]
  terminal_states: ["soc::done", "soc::failed"]

workspace:
  root: ${RUNTIME_DIR}/workspaces

polling:
  interval_ms: 1000

observability:
  dashboard_enabled: false
---
EOF

  printf 'WORKFLOW_FILE=%s\n' "$WORKFLOW_FILE"
  printf 'SYMPHONY_STAGE2_AGENT_TRACE=%s\n' "$AGENT_TRACE"
  printf 'FAKE_CODEX_MODE=%s\n' "$mode"
}

run_id() {
  if [ -n "${STAGE2_RUN_ID:-}" ]; then
    printf '%s' "$STAGE2_RUN_ID"
  else
    date -u '+symphony-stage2-%Y%m%dT%H%M%SZ'
  fi
}

issue_file() {
  local kind="$1"
  printf '%s/%s-issue.json' "$EVIDENCE_DIR" "$kind"
}

issue_iid() {
  local kind="$1"
  jq -r '.iid' "$(issue_file "$kind")"
}

create_issue() {
  local kind="$1"
  require_base_env
  require_tools
  init_dirs

  local title description issue_json
  title="$(run_id) ${kind} path"
  description="Synthetic Stage 2 ${kind}-path issue. No SOC data."

  issue_json="$(
    curl_json POST "/issues" \
      --data-urlencode "title=${title}" \
      --data-urlencode "description=${description}"
  )"

  printf '%s' "$issue_json" >"$(issue_file "$kind")"
  printf '%s' "$issue_json" | jq '{iid, web_url, title, state, labels}'
}

post_run() {
  local kind="$1"
  require_base_env
  require_tools
  init_dirs

  local source_kind="$kind"
  if [ "$kind" = "duplicate" ]; then
    source_kind="success"
  fi

  local iid
  iid="$(issue_iid "$source_kind")"

  curl_json POST "/issues/${iid}/notes" \
    --data-urlencode "body=/soc run" \
    >"${EVIDENCE_DIR}/${kind}-run-note.json"

  jq '{id, body, created_at, web_url}' "${EVIDENCE_DIR}/${kind}-run-note.json"
}

poll_issue() {
  local kind="$1"
  require_base_env
  require_tools
  init_dirs

  local iid target output
  iid="$(issue_iid "$kind")"

  case "$kind" in
    success) target="soc::human-review" ;;
    failure) target="soc::failed" ;;
    *)
      echo "poll requires success or failure" >&2
      exit 1
      ;;
  esac

  : >"${EVIDENCE_DIR}/${kind}-poll.log"

  for _ in $(seq 1 60); do
    output="$(curl_json GET "/issues/${iid}")"
    printf '%s' "$output" >"${EVIDENCE_DIR}/${kind}-final-issue.json"

    local labels
    labels="$(printf '%s' "$output" | jq -r '.labels | join(",")')"
    printf '%s labels=%s\n' "$(date -u +%H:%M:%S)" "$labels" \
      | tee -a "${EVIDENCE_DIR}/${kind}-poll.log"

    if printf '%s' "$output" | jq -e --arg target "$target" '.labels | index($target)' >/dev/null; then
      printf 'observed target label %s on issue %s\n' "$target" "$iid"
      return 0
    fi

    sleep 2
  done

  echo "timed out waiting for ${target}" >&2
  exit 1
}

fetch_notes() {
  local kind="$1"
  require_base_env
  require_tools
  init_dirs

  local iid
  iid="$(issue_iid "$kind")"

  curl_json GET "/issues/${iid}/notes" >"${EVIDENCE_DIR}/${kind}-notes.json"
  jq '[.[] | {id, body, created_at}]' "${EVIDENCE_DIR}/${kind}-notes.json"
}

verify_duplicate() {
  require_base_env
  require_tools
  init_dirs

  local iid completion_count issue_json notes_json
  iid="$(issue_iid success)"

  for _ in $(seq 1 15); do
    notes_json="$(curl_json GET "/issues/${iid}/notes")"
    printf '%s' "$notes_json" >"${EVIDENCE_DIR}/success-notes.json"
    completion_count="$(note_count "${EVIDENCE_DIR}/success-notes.json" 'soc::human-review')"

    if [ "$completion_count" -gt 1 ] 2>/dev/null; then
      jq -n \
        --arg result "Fail" \
        --arg reason "more than one completion comment observed" \
        --argjson completion_count "$completion_count" \
        '{result: $result, reason: $reason, completion_count: $completion_count}' \
        >"${EVIDENCE_DIR}/duplicate-verification.json"
      cat "${EVIDENCE_DIR}/duplicate-verification.json"
      exit 1
    fi

    sleep 2
  done

  issue_json="$(curl_json GET "/issues/${iid}")"
  printf '%s' "$issue_json" >"${EVIDENCE_DIR}/duplicate-final-issue.json"

  local final_label_result
  final_label_result="$(label_present_result "${EVIDENCE_DIR}/duplicate-final-issue.json" 'soc::human-review')"

  if [ "$completion_count" -eq 1 ] 2>/dev/null && [ "$final_label_result" = "Pass" ]; then
    jq -n \
      --arg result "Pass" \
      --arg reason "completion comment count remained one after duplicate command observation window" \
      --argjson completion_count "$completion_count" \
      '{result: $result, reason: $reason, completion_count: $completion_count}' \
      >"${EVIDENCE_DIR}/duplicate-verification.json"
    cat "${EVIDENCE_DIR}/duplicate-verification.json"
    return 0
  fi

  jq -n \
    --arg result "Fail" \
    --arg reason "duplicate verification did not preserve expected human-review state and single completion comment" \
    --argjson completion_count "${completion_count:-0}" \
    '{result: $result, reason: $reason, completion_count: $completion_count}' \
    >"${EVIDENCE_DIR}/duplicate-verification.json"
  cat "${EVIDENCE_DIR}/duplicate-verification.json"
  exit 1
}

token_boundary() {
  if [ ! -f "$AGENT_TRACE" ]; then
    echo "agent trace not found: ${AGENT_TRACE}" >&2
    exit 1
  fi

  if grep -Eq 'GITLAB_API_TOKEN=unset|GITLAB_API_TOKEN=$' "$AGENT_TRACE" &&
    grep -Eq 'GITLAB_WEBHOOK_SECRET=unset|GITLAB_WEBHOOK_SECRET=$' "$AGENT_TRACE"; then
    cat "$AGENT_TRACE"
    return 0
  fi

  echo "GitLab secret variables were visible to the agent process" >&2
  cat "$AGENT_TRACE" >&2
  exit 1
}

evidence_summary() {
  init_dirs
  printf 'EVIDENCE_DIR=%s\n' "$EVIDENCE_DIR"
  find "$EVIDENCE_DIR" -maxdepth 1 -type f | sort
}

json_value() {
  local file="$1"
  local filter="$2"

  if [ -f "$file" ]; then
    jq -r "$filter // \"Pending\"" "$file"
  else
    printf 'Pending'
  fi
}

note_count() {
  local file="$1"
  local pattern="$2"

  if [ -f "$file" ]; then
    jq --arg pattern "$pattern" '[.[] | select(.body | contains($pattern))] | length' "$file"
  else
    printf '0'
  fi
}

label_present_result() {
  local file="$1"
  local label="$2"

  if [ ! -f "$file" ]; then
    printf 'Pending'
    return
  fi

  if jq -e --arg label "$label" '.labels | index($label)' "$file" >/dev/null; then
    printf 'Pass'
  else
    printf 'Fail'
  fi
}

json_result() {
  local file="$1"

  if [ -f "$file" ]; then
    jq -r '.result // "Pending"' "$file"
  else
    printf 'Pending'
  fi
}

token_boundary_result() {
  if [ ! -f "$AGENT_TRACE" ]; then
    printf 'Pending'
    return
  fi

  if grep -Eq 'GITLAB_API_TOKEN=unset|GITLAB_API_TOKEN=$' "$AGENT_TRACE" &&
    grep -Eq 'GITLAB_WEBHOOK_SECRET=unset|GITLAB_WEBHOOK_SECRET=$' "$AGENT_TRACE"; then
    printf 'Pass'
  else
    printf 'Fail'
  fi
}

webhook_result() {
  if [ ! -f "${EVIDENCE_DIR}/webhook.json" ]; then
    printf 'Pending'
    return
  fi

  if jq -e '.url != null and .note_events == true and .enable_ssl_verification == true' \
    "${EVIDENCE_DIR}/webhook.json" >/dev/null; then
    printf 'Pass'
  else
    printf 'Fail'
  fi
}

write_report_row() {
  local check="$1"
  local evidence="$2"
  local result="$3"

  printf '| %s | %s | %s |\n' "$check" "$evidence" "$result"
}

render_report() {
  init_dirs

  local report_file="${EVIDENCE_DIR}/stage2-report.md"
  local success_url failure_url project_url
  local ack_count completion_count failure_count
  local success_label_result failure_label_result duplicate_result webhook_setup_result token_result

  success_url="$(json_value "$(issue_file success)" '.web_url')"
  failure_url="$(json_value "$(issue_file failure)" '.web_url')"
  project_url="$(json_value "${EVIDENCE_DIR}/project.json" '.web_url')"
  ack_count="$(note_count "${EVIDENCE_DIR}/success-notes.json" 'Symphony accepted')"
  completion_count="$(note_count "${EVIDENCE_DIR}/success-notes.json" 'soc::human-review')"
  failure_count="$(note_count "${EVIDENCE_DIR}/failure-notes.json" 'soc::failed')"
  success_label_result="$(label_present_result "${EVIDENCE_DIR}/success-final-issue.json" 'soc::human-review')"
  failure_label_result="$(label_present_result "${EVIDENCE_DIR}/failure-final-issue.json" 'soc::failed')"
  duplicate_result="$(json_result "${EVIDENCE_DIR}/duplicate-verification.json")"
  webhook_setup_result="$(webhook_result)"
  token_result="$(token_boundary_result)"

  {
    printf '# Stage 2 GitLab Staging Validation Report\n\n'
    printf 'Generated: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'Evidence directory: `%s`\n\n' "$EVIDENCE_DIR"

    printf '## Environment\n\n'
    printf '```text\n'
    print_safe_env
    printf '```\n\n'

    printf '## Commands\n\n'
    printf '```bash\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh preflight\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh ensure-labels\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh ensure-webhook\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh write-workflow success\n'
    printf 'cd elixir\n'
    printf 'mix setup\n'
    printf 'mix build\n'
    printf './bin/symphony /tmp/symphony-stage2/WORKFLOW.stage2.md --port 8080\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh create-success-issue\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh post-run success\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh poll success\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh notes success\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh post-run duplicate\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh verify-duplicate\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh notes success\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh token-boundary\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh write-workflow failure\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh create-failure-issue\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh post-run failure\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh poll failure\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh notes failure\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh token-boundary\n'
    printf 'specs/001-gitlab-control-plane/scripts/gitlab-stage2-validate.sh render-report\n'
    printf '```\n\n'

    printf '## Issue URLs\n\n'
    printf '%s\n' "- Staging project: ${project_url}"
    printf '%s\n' "- Success issue: ${success_url}"
    printf '%s\n\n' "- Failure issue: ${failure_url}"

    printf '## Results\n\n'
    printf '| Check | Evidence | Result |\n'
    printf '| --- | --- | --- |\n'
    write_report_row 'Staging project confirmed' "$project_url" "$(if [ "$project_url" = "Pending" ]; then printf 'Pending'; else printf 'Pass'; fi)"
    write_report_row 'Required labels setup attempted' "${EVIDENCE_DIR}/labels.jsonl" "$(if [ -f "${EVIDENCE_DIR}/labels.jsonl" ]; then printf 'Pass'; else printf 'Pending'; fi)"
    write_report_row 'Webhook configured for note events' "${EVIDENCE_DIR}/webhook.json" "$webhook_setup_result"
    write_report_row 'Success issue reached soc::human-review' "${EVIDENCE_DIR}/success-final-issue.json" "$success_label_result"
    write_report_row 'Acknowledgement comment count' "$ack_count" "$(if [ "$ack_count" -eq 1 ] 2>/dev/null; then printf 'Pass'; else printf 'Pending'; fi)"
    write_report_row 'Completion comment count' "$completion_count" "$(if [ "$completion_count" -eq 1 ] 2>/dev/null; then printf 'Pass'; else printf 'Pending'; fi)"
    write_report_row 'Duplicate run verification' "${EVIDENCE_DIR}/duplicate-verification.json" "$duplicate_result"
    write_report_row 'Failure issue reached soc::failed' "${EVIDENCE_DIR}/failure-final-issue.json" "$failure_label_result"
    write_report_row 'Failure comment count' "$failure_count" "$(if [ "$failure_count" -eq 1 ] 2>/dev/null; then printf 'Pass'; else printf 'Pending'; fi)"
    write_report_row 'Local Codex token boundary' "$AGENT_TRACE" "$token_result"
    write_report_row 'Remote Codex token boundary' 'not exercised unless remote worker is configured' 'Pending'
    write_report_row 'Branch or MR creation' 'not part of helper commands' 'Pass'
    write_report_row 'Out-of-scope SOC actions' 'not part of helper commands' 'Pass'

    printf '\n## Remaining Risks\n\n'
    printf '%s\n' '- Live webhook delivery is unproven until GitLab can reach `GITLAB_WEBHOOK_PUBLIC_URL`.'
    printf '%s\n' '- Remote token boundary remains pending unless a remote worker is used.'
    printf '%s\n' '- In-memory webhook idempotency still resets on service restart.'
    printf '%s\n' '- Duplicate `/soc run` after terminal handoff must be reviewed from notes and Symphony logs.'
  } >"$report_file"

  printf 'REPORT_FILE=%s\n' "$report_file"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [ "$actual" = "$expected" ]; then
    printf 'PASS: %s\n' "$label"
    return 0
  fi

  printf 'FAIL: %s expected=%s actual=%s\n' "$label" "$expected" "$actual" >&2
  return 1
}

assert_file() {
  local file="$1"
  local label="$2"

  if [ -s "$file" ]; then
    printf 'PASS: %s\n' "$label"
    return 0
  fi

  printf 'FAIL: %s missing file %s\n' "$label" "$file" >&2
  return 1
}

assert_json_filter() {
  local file="$1"
  local filter="$2"
  local label="$3"

  if [ -s "$file" ] && jq -e "$filter" "$file" >/dev/null; then
    printf 'PASS: %s\n' "$label"
    return 0
  fi

  printf 'FAIL: %s did not match %s in %s\n' "$label" "$filter" "$file" >&2
  return 1
}

assert_complete() {
  init_dirs

  local failures=0
  local ack_count completion_count failure_count

  ack_count="$(note_count "${EVIDENCE_DIR}/success-notes.json" 'Symphony accepted')"
  completion_count="$(note_count "${EVIDENCE_DIR}/success-notes.json" 'soc::human-review')"
  failure_count="$(note_count "${EVIDENCE_DIR}/failure-notes.json" 'soc::failed')"

  assert_file "${EVIDENCE_DIR}/project.json" 'staging project evidence exists' || failures=$((failures + 1))
  assert_file "${EVIDENCE_DIR}/labels.jsonl" 'label setup evidence exists' || failures=$((failures + 1))
  assert_json_filter "${EVIDENCE_DIR}/webhook.json" '.url != null and .note_events == true and .enable_ssl_verification == true' 'webhook configured for note events' || failures=$((failures + 1))
  assert_json_filter "$(issue_file success)" '(.web_url != null) and (.description | contains("Synthetic Stage 2"))' 'success issue is synthetic staging data' || failures=$((failures + 1))
  assert_json_filter "${EVIDENCE_DIR}/success-final-issue.json" '.labels | index("soc::human-review")' 'success issue reached human review' || failures=$((failures + 1))
  assert_equals '1' "$ack_count" 'one acknowledgement comment on success issue' || failures=$((failures + 1))
  assert_equals '1' "$completion_count" 'one completion comment on success issue' || failures=$((failures + 1))
  assert_json_filter "${EVIDENCE_DIR}/duplicate-verification.json" '.result == "Pass"' 'duplicate run verification passed' || failures=$((failures + 1))
  assert_json_filter "$(issue_file failure)" '(.web_url != null) and (.description | contains("Synthetic Stage 2"))' 'failure issue is synthetic staging data' || failures=$((failures + 1))
  assert_json_filter "${EVIDENCE_DIR}/failure-final-issue.json" '.labels | index("soc::failed")' 'failure issue reached failed state' || failures=$((failures + 1))
  assert_equals '1' "$failure_count" 'one failure comment on failure issue' || failures=$((failures + 1))

  if [ "$(token_boundary_result)" = "Pass" ]; then
    printf 'PASS: local Codex token boundary\n'
  else
    printf 'FAIL: local Codex token boundary\n' >&2
    failures=$((failures + 1))
  fi

  if [ "$failures" -eq 0 ]; then
    printf 'Stage 2 evidence is complete.\n'
    return 0
  fi

  printf 'Stage 2 evidence is incomplete: %s failure(s).\n' "$failures" >&2
  return 1
}

main() {
  local command="${1:-}"
  shift || true

  case "$command" in
    preflight) preflight ;;
    ensure-labels) ensure_labels ;;
    list-webhooks) list_webhooks ;;
    ensure-webhook) ensure_webhook ;;
    write-workflow) write_workflow "${1:-}" ;;
    create-success-issue) create_issue success ;;
    create-failure-issue) create_issue failure ;;
    post-run) post_run "${1:-}" ;;
    verify-duplicate) verify_duplicate ;;
    poll) poll_issue "${1:-}" ;;
    notes) fetch_notes "${1:-}" ;;
    token-boundary) token_boundary ;;
    evidence-summary) evidence_summary ;;
    render-report) render_report ;;
    assert-complete) assert_complete ;;
    ""|help|--help|-h) usage ;;
    *)
      echo "unknown command: ${command}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

load_env_file
main "$@"
