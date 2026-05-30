#!/usr/bin/env bash
set -euo pipefail

readonly RUNTIME_DIR="${STAGE2_RUNTIME_DIR:-/tmp/symphony-stage2}"
readonly EVIDENCE_DIR="${STAGE2_EVIDENCE_DIR:-${RUNTIME_DIR}/evidence}"
readonly WORKFLOW_FILE="${STAGE2_WORKFLOW_FILE:-${RUNTIME_DIR}/WORKFLOW.stage2.md}"
readonly AGENT_TRACE="${SYMPHONY_STAGE2_AGENT_TRACE:-${RUNTIME_DIR}/agent-env.trace}"
readonly FAKE_CODEX="${RUNTIME_DIR}/fake-codex-stage2"

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
  gitlab-stage2-validate.sh write-workflow success|failure
  gitlab-stage2-validate.sh create-success-issue
  gitlab-stage2-validate.sh post-run success|failure|duplicate
  gitlab-stage2-validate.sh poll success|failure
  gitlab-stage2-validate.sh notes success|failure
  gitlab-stage2-validate.sh token-boundary
  gitlab-stage2-validate.sh evidence-summary

Required environment, values must not be printed:
  GITLAB_ENDPOINT
  GITLAB_PROJECT_ID
  GITLAB_PROJECT_SLUG
  GITLAB_API_TOKEN
  GITLAB_WEBHOOK_SECRET
  GITLAB_WEBHOOK_PUBLIC_URL
  STAGE2_CONFIRM_DISPOSABLE_PROJECT=yes

Optional:
  STAGE2_RUN_ID
  STAGE2_RUNTIME_DIR
  STAGE2_EVIDENCE_DIR
  STAGE2_WORKFLOW_FILE
  SYMPHONY_STAGE2_AGENT_TRACE
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_env() {
  local missing=0
  for name in \
    GITLAB_ENDPOINT \
    GITLAB_PROJECT_ID \
    GITLAB_PROJECT_SLUG \
    GITLAB_API_TOKEN \
    GITLAB_WEBHOOK_SECRET \
    GITLAB_WEBHOOK_PUBLIC_URL
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

require_tools() {
  require_command curl
  require_command jq
}

init_dirs() {
  mkdir -p "$RUNTIME_DIR" "$EVIDENCE_DIR"
}

api_url() {
  local path="$1"
  printf '%s/api/v4/projects/%s%s' \
    "${GITLAB_ENDPOINT%/}" \
    "${GITLAB_PROJECT_ID}" \
    "$path"
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
  require_env
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
  require_env
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

write_workflow() {
  local mode="${1:-}"
  if [ "$mode" != "success" ] && [ "$mode" != "failure" ]; then
    echo "write-workflow requires success or failure" >&2
    exit 1
  fi

  require_env
  init_dirs

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
agent:
  codex:
    command: ${FAKE_CODEX} app-server

tracker:
  kind: gitlab
  endpoint: \$GITLAB_ENDPOINT
  api_key: \$GITLAB_API_TOKEN
  project_slug: \$GITLAB_PROJECT_SLUG
  webhook_secret: \$GITLAB_WEBHOOK_SECRET
  active_states: ["soc::queued"]
  terminal_states: ["soc::done", "soc::failed"]

workspace:
  root: ${RUNTIME_DIR}/workspaces

polling:
  interval_ms: 1000
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
  require_env
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
  require_env
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
  require_env
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
  require_env
  require_tools
  init_dirs

  local iid
  iid="$(issue_iid "$kind")"

  curl_json GET "/issues/${iid}/notes" >"${EVIDENCE_DIR}/${kind}-notes.json"
  jq '[.[] | {id, body, created_at}]' "${EVIDENCE_DIR}/${kind}-notes.json"
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

main() {
  local command="${1:-}"
  shift || true

  case "$command" in
    preflight) preflight ;;
    ensure-labels) ensure_labels ;;
    write-workflow) write_workflow "${1:-}" ;;
    create-success-issue) create_issue success ;;
    create-failure-issue) create_issue failure ;;
    post-run) post_run "${1:-}" ;;
    poll) poll_issue "${1:-}" ;;
    notes) fetch_notes "${1:-}" ;;
    token-boundary) token_boundary ;;
    evidence-summary) evidence_summary ;;
    ""|help|--help|-h) usage ;;
    *)
      echo "unknown command: ${command}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
