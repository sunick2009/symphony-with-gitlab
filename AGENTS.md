<!-- SPECKIT START -->
For additional context about the active GitLab merge request workflow effort,
read `specs/002-gitlab-mr-workflow/plan.md` before modifying implementation.
<!-- SPECKIT END -->

## Agent Workflow

This repo uses `elixir/WORKFLOW.gitlab.md` as the canonical GitLab agent workflow template.
The workflow enforces structured multi-phase execution: planning → execution → evidence → review.

### Multi-phase execution model

- **Planning mode** (no `CONTEXT.md` in workspace): Codex analyzes the issue and writes
  `output/workpad.md` with a phased checklist. It ends the turn without executing.
- **Execution mode** (`CONTEXT.md` present, injected by `before_run` hook): Codex reads
  current workpad state, executes the next unchecked Phase, writes real output to
  `output/evidence/phase-N.md`, updates the workpad, then ends the turn.
- **`after_run` hook** validates that every checked `[x] Phase N` has a corresponding
  `output/evidence/phase-N.md` (> 20 bytes). Missing evidence causes the hook to fail
  and prevents the GitLab workpad comment from being updated.

### Known architectural limitation

`before_run` and `after_run` hooks are called once per agent run (not between turns).
The GitLab workpad comment is updated only after all turns complete — not after each
individual phase. Per-turn updates require changes to `agent_runner.ex`.

### Spec-kit integration (future)

If an issue description follows spec-kit format with `### Acceptance Criteria`, the
WORKFLOW.md prompt can map each criterion directly to a Phase, using the criterion text
as the evidence standard. No Symphony code changes required — update the prompt only.
See memory file `project-speckit-integration.md` for the full design.
