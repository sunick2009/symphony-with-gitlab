# Contract: GitLab Webhook Control Plane

## Endpoint

`POST /api/v1/gitlab/webhook`

## Required Headers

- `X-Gitlab-Token`: Must equal configured `tracker.webhook_secret`.
- `X-Gitlab-Event`: GitLab event type. Supported for this phase: `Note Hook`; `Issue Hook` may be accepted and ignored.
- `X-Gitlab-Event-UUID`: Preferred idempotency key when present.

## Supported Note Hook Payload Shape

Required fields:

- `object_attributes.note`: Comment body.
- `object_attributes.noteable_type`: Must identify an issue.
- `issue.iid` or `object_attributes.noteable_iid`: GitLab issue IID.
- `issue.state`: Open or closed issue state when available.
- `issue.labels`: Current issue labels when available.

## Responses

- `200` with `{"status":"handled"}` when a supported command is processed.
- `200` with `{"status":"ignored"}` when a validated event has no actionable command.
- `200` with `{"status":"duplicate"}` when the delivery was already processed in the current service lifetime.
- `401` when the webhook token is missing or invalid.
- `422` when a required issue identifier is missing or command handling fails.
- `503` when the service is not configured with a webhook secret.

## `/soc run` Effects

On accepted `/soc run`:

- Add configured queued lifecycle label.
- Remove conflicting lifecycle labels.
- Post an acknowledgement comment.
- Do not dispatch directly from the controller; dispatch remains orchestrator-owned through polling/reconciliation.

On rejected `/soc run`:

- Closed issue: post a rejection comment.
- Already claimed or running issue: post a duplicate-run rejection comment.
- No label transition occurs.

## Token Boundary

GitLab write tokens are consumed only by the GitLab adapter/client. They are not included in Codex prompts, Codex app-server environment, or turn payloads by this contract.
