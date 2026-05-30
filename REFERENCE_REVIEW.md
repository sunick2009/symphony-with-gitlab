# Reference Review: Dripmaster/symphony-py

The repository at `https://github.com/Dripmaster/symphony-py` was cloned into `/workspaces/reference/symphony-py-readonly` and made read-only. It was consulted only for conceptual orientation.

Conceptual observations:

- GitLab can act as a Symphony issue source through project issue polling.
- Label-based workflow states are a practical control-plane model for GitLab issues.
- GitLab issue polling should account for the distinction between project issue IIDs and other issue identifiers.
- Terminal labels should take precedence over active labels when deriving a single workflow state.
- Querying separate active labels may require deduplication when an issue has more than one relevant label.
- A polling-oriented implementation still needs additional webhook, command parsing, idempotency, comment writeback, and label mutation boundaries for an interactive bot adapter.

Clean-room confirmation:

- No source files, tests, comments, documentation sections, or implementation snippets were copied from the reference repository.
- No Python structures were mechanically translated into this Elixir implementation.
- No reference repository dependency was added, vendored, imported, or embedded.
