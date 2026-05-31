# Data Model: GitLab Merge Request Workflow

## Overview

Stage 4 extends the existing GitLab control-plane state with repository mutation and CI reconciliation records. The design remains single-node and file-backed.

## Entities

### Stage4ArtifactManifest

- **Purpose**: Adapter-approved description of what the agent produced and what may be committed.
- **Fields**:
  - `issue_iid`: originating GitLab issue IID
  - `run_fingerprint`: stable digest of normalized artifact content and metadata
  - `workspace_path`: isolated workspace path used for collection
  - `target_branch`: target branch for the MR, typically the project default branch
  - `actions`: normalized file actions for the GitLab Commits API
  - `summary`: short human-readable summary for commit and MR text
  - `collected_at`: timestamp
- **Validation**:
  - All paths must resolve under the repository root in the isolated workspace.
  - Unsupported file actions or oversized payloads must be rejected before mutation.
  - Empty action sets produce a no-change outcome rather than a commit.

### RepositoryMutationRecord

- **Purpose**: Persistent idempotency and audit record for one Stage 4 run.
- **Fields**:
  - `issue_iid`
  - `run_fingerprint`
  - `branch_name`
  - `branch_status`: `pending | done | failed | reused`
  - `commit_sha`
  - `commit_status`: `pending | done | failed | reused`
  - `merge_request_iid`
  - `merge_request_url`
  - `merge_request_status`: `pending | done | failed | reused`
  - `attempts`
  - `last_error`
  - `updated_at`
- **Validation**:
  - Operation keys must be unique per issue IID plus run fingerprint.
  - Reuse status requires provenance verification before marking `reused`.

### BranchProvenance

- **Purpose**: Deterministic metadata that proves a branch belongs to a specific issue run.
- **Fields**:
  - `branch_name`
  - `issue_iid`
  - `run_fingerprint`
  - `target_branch`
  - `created_by`: adapter identity string
  - `created_at`
- **Validation**:
  - Branch name must follow the Stage 4 branch pattern.
  - Provenance values must match the artifact manifest before branch reuse.

### MergeRequestProjection

- **Purpose**: Adapter-owned record of the review artifact created for one run.
- **Fields**:
  - `issue_iid`
  - `merge_request_iid`
  - `merge_request_url`
  - `source_branch`
  - `target_branch`
  - `title`
  - `description_digest`
  - `state`: `opened | merged | closed`
  - `latest_pipeline_status`
  - `updated_at`
- **Validation**:
  - Source branch and target branch must match the current mutation record before reuse.
  - Only one open MR per issue IID and run fingerprint should be considered authoritative.

### CiObservation

- **Purpose**: Normalized view of the newest relevant CI result for the Stage 4 MR.
- **Fields**:
  - `merge_request_iid`
  - `pipeline_id`
  - `pipeline_sha`
  - `status`: `pending | running | success | failed | canceled | skipped | unknown`
  - `status_group`
  - `details_url`
  - `observed_at`
  - `last_issue_writeback_key`
- **Validation**:
  - Only the newest relevant pipeline for the MR source branch or MR pipeline context should drive writeback.
  - Repeated observations of the same status class should not create duplicate issue notes.

## Relationships

- One **Stage4ArtifactManifest** creates at most one authoritative **RepositoryMutationRecord**.
- One **RepositoryMutationRecord** owns zero or one **MergeRequestProjection**.
- One **MergeRequestProjection** can accumulate many **CiObservation** records over time.
- One GitLab issue IID can have multiple Stage 4 attempts, each distinguished by `run_fingerprint`.

## State Transitions

### Repository Mutation

`collected` → `branch_done` → `commit_done` → `mr_done` → `issue_linked`

Failure may occur at each step. Retry resumes from the first incomplete step after verifying prior mutation state.

### CI Observation

`pending/running` → `success`

or

`pending/running` → `failed/canceled`

CI transitions do not auto-merge or auto-close the MR in Stage 4.
