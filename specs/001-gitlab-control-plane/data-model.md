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
- Duplicate event UUID or fallback object ID is processed at most once per service lifetime.
- Unsupported event types are ignored after validation.

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
- Writeback failures must be logged or surfaced in tests.
