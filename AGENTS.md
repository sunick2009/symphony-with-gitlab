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
- **Execution mode** (`CONTEXT.md` present, injected by `before_turn` hook): Codex reads
  current workpad state, executes the next unchecked Phase, writes real output to
  `output/evidence/phase-N.md`, updates the workpad, then ends the turn.
- **`after_turn` hook** validates that every checked `[x] Phase N` has a corresponding
  `output/evidence/phase-N.md` (> 20 bytes). Missing evidence causes the hook to fail
  and skips the GitLab workpad comment update for that turn.

### Hook timing (per-turn vs per-run)

Symphony runs workspace hooks at two granularities:

- **Per-run** (once per agent run): `after_create`, `before_run`, `after_run`, `before_remove`.
- **Per-turn** (once per Codex turn): `before_turn`, `after_turn`. Implemented in
  `agent_runner.ex` `do_run_codex_turns/9`, wrapping each `AppServer.run_turn` call.

The full ordering for an N-turn run is:
`before_run → (before_turn → turn → after_turn) × N → after_run`.

Per-turn hooks are **non-fatal**: a failure is logged but never aborts the run (they are
observability/sync points, and touch the network every turn). This is what makes
"plan first, then execute" work — the plan written in turn 1 syncs to GitLab via
`after_turn` before turn 2 begins. See `specs/004-per-turn-hooks/spec.md`.

### Spec-kit integration (future)

If an issue description follows spec-kit format with `### Acceptance Criteria`, the
WORKFLOW.md prompt can map each criterion directly to a Phase, using the criterion text
as the evidence standard. No Symphony code changes required — update the prompt only.
See memory file `project-speckit-integration.md` for the full design.
