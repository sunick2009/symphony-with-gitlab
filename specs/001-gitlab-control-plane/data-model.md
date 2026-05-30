# Data Model: GitLab Control Plane

## GitLab Issue

Represents one GitLab project issue normalized for Symphony orchestration.

Fields:

- `id`: GitLab project issue IID as a string for this phase.
- `identifier`: Human-readable issue reference such as `#42`.
- `title`: Issue title.
- `description`: Issue body or nil.
- `state`: Derived workflow state from labels or GitLab open/closed state.
- `labels`: Lowercase label names for internal comparison.
- `url`: GitLab web URL.
- `created_at` and `updated_at`: Optional timestamps.

Validation rules:

- `id`, `identifier`, `title`, and `state` are required for dispatch eligibility.
- Terminal labels take precedence over active labels.
- Closed GitLab issues are terminal regardless of active labels.

## GitLab Webhook Delivery

Represents one incoming GitLab project webhook request.

Fields:

- `event_type`: Header value such as `Note Hook` or `Issue Hook`.
- `event_uuid`: Delivery UUID header when present.
- `object_id`: Fallback object identifier from payload.
- `secret`: Header token used for validation.
- `payload`: Parsed JSON body.

Validation rules:

- Secret must match configured `tracker.webhook_secret`.
- Duplicate event UUID or fallback object ID is processed at most once across process restarts when persistent state is retained.
- Unsupported event types are ignored after validation.
- Processing outcome is recorded as handled, ignored, duplicate, or failed without storing the webhook secret or full issue body.

## Persistent Control-Plane State

Represents local durable audit and idempotency state for one Symphony GitLab control-plane deployment.

Fields:

- `schema_version`: State file schema version.
- `webhook_events`: Map of delivery keys to event type, issue IID when known, status, timestamps, and sanitized result.
- `writebacks`: Map of operation keys to operation type, issue IID, lifecycle or comment key, status, attempt count, timestamps, and sanitized final reason.
- `issue_runs`: Map of issue IID to latest known lifecycle marker and run-related timestamps.

Validation rules:

- State must be written atomically.
- State must not contain GitLab API tokens, webhook secrets, raw issue descriptions, raw comments, agent prompts, or agent output.
- Malformed or unreadable state is treated as an operational error rather than silently discarding idempotency.
- Completed writeback records suppress duplicate lifecycle comments and duplicate lifecycle transitions after restart.

## Bot Command

Represents one parsed `/soc` command in an issue comment.

Fields:

- `name`: Command name, one of `run`, `status`, `retry`, `cancel`.
- `raw`: Original command line.

Validation rules:

- Command must start at the beginning of a line.
- Only `/soc run` triggers queueing in this phase.
- Other known commands receive a not-implemented response.
- Unknown commands receive an unsupported-command response.

## Lifecycle Transition

Represents one adapter-owned label mutation.

Fields:

- `issue_iid`: GitLab project issue IID.
- `target_label`: Label to add.
- `conflicting_labels`: Lifecycle labels to remove.

Validation rules:

- Exactly one target lifecycle label is added.
- Conflicting lifecycle labels are removed.
- Unrelated labels are not removed by Symphony.

## Adapter Writeback

Represents an adapter-owned GitLab mutation.

Types:

- Issue comment.
- Issue label update.

Validation rules:

- Writeback requires GitLab adapter configuration.
- Codex agent turns must not hold GitLab write tokens.
- Writeback failures must be retried only within configured bounds.
- Retry exhaustion must be recorded in persistent state.
- Completed lifecycle writebacks must be idempotent across process restarts.

## Writeback Attempt

Represents one attempt to perform a GitLab API mutation.

Fields:

- `operation_key`: Stable key for the lifecycle transition or lifecycle comment.
- `issue_iid`: GitLab issue IID.
- `operation`: Label transition or issue comment.
- `attempt`: Positive attempt number.
- `status`: Success, retryable failure, permanent failure, or exhausted failure.
- `reason`: Sanitized status or error category.
- `recorded_at`: UTC timestamp.

Validation rules:

- Attempts must be bounded by configuration.
- Retryable statuses are transport errors, HTTP 429, and HTTP 5xx.
- Permission and validation errors are surfaced without unbounded retry.
