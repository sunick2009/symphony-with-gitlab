# Feature Specification: Docker Single-Machine Deployment

**Feature Branch**: `003-docker-deployment`

**Created**: 2026-06-03

**Status**: Draft

**Input**: Package Symphony as a single Docker container for single-machine deployment, with a configurable pre-flight health check that detects Codex auth failures before an agent run begins.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Detect Codex Auth Failures Before Agent Runs (Priority: P1)

An operator running Symphony in a container mounts their Codex auth token from the host. When the token expires mid-deployment, Symphony detects the invalid auth at the start of a new agent run and surfaces a clear error instead of failing deep inside a turn with a cryptic message.

**Why this priority**: Auth token expiry is the most common runtime failure in subscription-based Codex deployments. Detecting it early, before spawning the app-server process, reduces wasted work and produces actionable errors for the operator.

**Independent Test**: Configure `codex.health_check_command` with a command that exits non-zero, call `AppServer.start_session/2`, and verify it returns `{:error, {:codex_health_check_failed, ...}}` without attempting to spawn the app-server process.

**Acceptance Scenarios**:

1. **Given** `codex.health_check_command` is set and exits `0`, **When** `AppServer.start_session/2` is called, **Then** the session starts normally and the health check result is not surfaced to the caller.
2. **Given** `codex.health_check_command` is set and exits non-zero, **When** `AppServer.start_session/2` is called, **Then** it returns `{:error, {:codex_health_check_failed, status, output}}` and no app-server process is spawned.
3. **Given** `codex.health_check_command` is `null` or absent, **When** `AppServer.start_session/2` is called, **Then** no health check runs and the session starts normally.
4. **Given** `codex.health_check_command` is set and exits non-zero on a remote SSH worker, **When** `AppServer.start_session/2` is called with `worker_host`, **Then** it returns `{:error, {:codex_health_check_failed, status, output}}` without opening an SSH app-server port.

---

### User Story 2 - Deploy Symphony as a Single Docker Container (Priority: P1)

An operator wants to run Symphony on a single machine without installing Elixir, Codex, or their dependencies directly on the host. They provide a `WORKFLOW.md`, a persisted workspace directory, and their Codex auth token directory via volume mounts, then start Symphony with `docker compose up`.

**Why this priority**: Containerization removes the per-host toolchain setup burden and makes Symphony portable across environments.

**Independent Test**: Build the Docker image and verify `symphony --help` exits `0`. Verify that the container accepts `WORKFLOW.md` at `/app/WORKFLOW.md` and that workspace and state directories are written to the declared volume paths.

**Acceptance Scenarios**:

1. **Given** a built Docker image, a `WORKFLOW.md`, and a volume for `/workspaces`, **When** the container starts, **Then** Symphony reads the workflow from `/app/WORKFLOW.md` and writes workspaces under `/workspaces`.
2. **Given** a `~/.codex/` directory with a valid auth token mounted at `/root/.codex`, **When** Symphony starts a Codex run, **Then** Codex authenticates via the mounted token without requiring `OPENAI_API_KEY`.
3. **Given** `codex.health_check_command` is configured, **When** the auth token has expired, **Then** Symphony logs a clear health check failure and does not start a Codex app-server process.

---

### Edge Cases

- What happens when the health check command itself is not found on `PATH`? The exit status is non-zero and the error output is surfaced in the failure tuple.
- What happens when `health_check_command` is an empty string? Treated as absent; no health check runs.
- What happens when the mounted `/root/.codex` directory is read-only? Codex auth reads the token but cannot refresh; the health check detects expiry at the next run.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `codex.health_check_command` MUST be an optional string field in `WORKFLOW.md` config.
- **FR-002**: When set and non-empty, Symphony MUST run the health check command before spawning the Codex app-server port.
- **FR-003**: A non-zero health check exit MUST produce `{:error, {:codex_health_check_failed, exit_status, output}}` from `AppServer.start_session/2`.
- **FR-004**: When `health_check_command` is absent or empty, `AppServer.start_session/2` behavior MUST be unchanged.
- **FR-005**: For SSH workers, the health check MUST run on the remote host before the SSH app-server port is opened.
- **FR-006**: The `Dockerfile` MUST produce a runnable image from a single `docker build` invocation at the repository root.
- **FR-007**: The `docker-compose.yml` MUST declare volume mounts for workspaces, state, and Codex auth.

### Key Entities

- **`codex.health_check_command`**: Optional string. Shell command run before each `AppServer.start_session`. Exit `0` = healthy; non-zero = fail session start.
- **Codex auth volume**: Host directory `~/.codex` mounted at `/root/.codex` in the container. Holds OAuth token written by `codex auth` on the host.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `AppServer.start_session/2` returns `{:error, {:codex_health_check_failed, _, _}}` when `health_check_command` exits non-zero, verified by ExUnit tests.
- **SC-002**: `AppServer.start_session/2` proceeds to open a port when `health_check_command` exits `0`, verified by ExUnit tests.
- **SC-003**: No health check overhead when `health_check_command` is absent, verified by ExUnit tests.
- **SC-004**: `docker build` completes without error on the project Dockerfile.

## Assumptions

- Single-machine deployment uses local mode only; `worker.ssh_hosts` is empty in the containerized `WORKFLOW.md`.
- The operator runs `codex auth` on the host before mounting `~/.codex`; Symphony does not initiate OAuth flows.
- The `health_check_command` is a fast command (e.g., `codex whoami`) with sub-second expected runtime; no timeout is applied beyond the OS default.
- Docker and Docker Compose are available on the deployment host; the image is not published to a registry in this feature.
