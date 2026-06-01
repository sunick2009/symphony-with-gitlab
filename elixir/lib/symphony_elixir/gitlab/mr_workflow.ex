defmodule SymphonyElixir.GitLab.MRWorkflow do
  @moduledoc """
  Stage 4 GitLab merge request workflow helpers.
  """

  require Logger

  alias SymphonyElixir.{Config, GitLab.Adapter, GitLab.Audit, GitLab.StateStore, Linear.Issue, PathSafety}

  @branch_prefix "soc/issue-"
  @manifest_relpath ".symphony/gitlab_artifacts.json"
  @manifest_version 1
  @max_artifact_bytes 262_144
  @default_target_branch "main"
  @allowed_repo_prefixes ["elixir/", "specs/", ".specify/", ".agents/"]
  @allowed_repo_exact ["README.md", "AGENTS.md", ".gitlab-ci.yml"]
  @blocked_path_segments [".git", ".codex"]
  @blocked_path_suffixes [
    ".env",
    ".env.local",
    ".pem",
    ".key",
    "auth.json",
    "config.json",
    "settings.json",
    ".gitlab-control-plane-state.json"
  ]
  @blocked_path_substrings [
    "/tunnels/",
    "/tunnel/",
    "/secrets/",
    "/tokens/",
    "/auth/",
    "/state/"
  ]
  @allowed_text_content_types [
    "text/plain",
    "text/markdown",
    "text/x-elixir",
    "application/json",
    "application/x-yaml",
    "text/yaml"
  ]
  @ci_pending_statuses MapSet.new(["pending", "created", "preparing", "scheduled", "waiting_for_resource"])
  @ci_running_statuses MapSet.new(["running"])
  @ci_success_statuses MapSet.new(["success"])
  @ci_failure_statuses MapSet.new(["failed", "canceled"])
  @ci_unknown_statuses MapSet.new(["skipped", "manual", "unknown"])

  @type artifact_manifest :: %{
          version: pos_integer(),
          artifacts: [artifact_entry()]
        }

  @type artifact_entry :: %{
          repository_path: String.t(),
          workspace_source_path: String.t(),
          action: String.t(),
          description: String.t() | nil,
          content_type: String.t() | nil,
          metadata: map()
        }

  @type commit_action :: %{
          action: String.t(),
          file_path: String.t(),
          content: String.t()
        }

  @type dry_run_plan :: %{
          issue_iid: String.t(),
          run_fingerprint: String.t(),
          source_branch: String.t(),
          target_branch: String.t(),
          commit_message: String.t(),
          merge_request_title: String.t(),
          merge_request_description: String.t(),
          commit_actions: [commit_action()],
          manifest_digest: String.t() | nil,
          collected_artifact_digest: String.t() | nil,
          action_digest: String.t() | nil,
          branch_name: String.t(),
          would_create_branch: boolean(),
          would_create_commit: boolean(),
          would_create_merge_request: boolean(),
          no_op: boolean()
        }

  @spec manifest_relpath() :: String.t()
  def manifest_relpath, do: @manifest_relpath

  @spec branch_name(String.t(), String.t()) :: String.t()
  def branch_name(issue_iid, run_fingerprint)
      when is_binary(issue_iid) and is_binary(run_fingerprint) do
    sanitized_issue_iid =
      issue_iid
      |> sanitize_branch_component()

    sanitized_fingerprint =
      run_fingerprint
      |> sanitize_branch_component()

    "#{@branch_prefix}#{sanitized_issue_iid}/#{sanitized_fingerprint}"
  end

  @spec finalize_dry_run(Issue.t() | map(), Path.t() | nil, keyword()) ::
          {:ok, {:planned, dry_run_plan()}}
          | {:ok, {:noop, dry_run_plan()}}
          | {:error, term()}
  def finalize_dry_run(%Issue{id: issue_iid} = issue, workspace_path, opts) when is_binary(issue_iid) do
    do_finalize_dry_run(issue, workspace_path, opts)
  end

  def finalize_dry_run(%{id: issue_iid} = issue, workspace_path, opts) when is_binary(issue_iid) do
    do_finalize_dry_run(struct(Issue, issue), workspace_path, opts)
  end

  @spec finalize_issue_completion(Issue.t() | map(), Path.t() | nil, keyword()) ::
          {:ok, {:planned, dry_run_plan()}}
          | {:ok, {:noop, dry_run_plan()}}
          | {:ok, {:executed, dry_run_plan(), map()}}
          | {:error, term()}
  def finalize_issue_completion(%Issue{} = issue, workspace_path, opts) do
    with {:ok, result} <- finalize_dry_run(issue, workspace_path, opts) do
      maybe_execute_live_plan(issue, result, opts)
    end
  end

  def finalize_issue_completion(%{id: _issue_iid} = issue, workspace_path, opts) do
    finalize_issue_completion(struct(Issue, issue), workspace_path, opts)
  end

  @spec write_merge_request_link_comment(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def write_merge_request_link_comment(issue_iid, run_fingerprint, merge_request_url, source_branch)
      when is_binary(issue_iid) and is_binary(run_fingerprint) and is_binary(merge_request_url) and
             is_binary(source_branch) do
    result =
      Adapter.create_comment_once(
        issue_iid,
        "mr:#{run_fingerprint}:link",
        "Symphony created merge request: #{merge_request_url} from branch `#{source_branch}`.",
        %{
          run_fingerprint: run_fingerprint,
          merge_request_url: merge_request_url,
          source_branch: source_branch,
          status_class: "mr-linked"
        }
      )

    if result == :ok do
      Audit.emit("mr_link_comment.written", %{
        issue_iid: issue_iid,
        run_fingerprint: run_fingerprint,
        merge_request_url: merge_request_url,
        source_branch: source_branch
      })
    end

    result
  end

  @spec write_ci_failure_comment(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def write_ci_failure_comment(issue_iid, merge_request_iid, merge_request_url, pipeline_status)
      when is_binary(issue_iid) and is_binary(merge_request_iid) and is_binary(merge_request_url) and
             is_binary(pipeline_status) do
    Adapter.create_comment_once(
      issue_iid,
      "mr:#{merge_request_iid}:ci:#{pipeline_status}",
      "Symphony observed CI status `#{pipeline_status}` for merge request #{merge_request_url}.",
      %{
        merge_request_iid: merge_request_iid,
        merge_request_url: merge_request_url,
        pipeline_status: pipeline_status,
        status_class: "ci-failure"
      }
    )
  end

  @spec reconcile_merge_request_ci(Issue.t() | map() | String.t()) ::
          {:ok, :no_merge_request | :no_pipeline | map()} | {:error, term()}
  def reconcile_merge_request_ci(%Issue{id: issue_iid}) when is_binary(issue_iid) do
    reconcile_merge_request_ci(issue_iid)
  end

  def reconcile_merge_request_ci(%{id: issue_iid}) when is_binary(issue_iid) do
    reconcile_merge_request_ci(issue_iid)
  end

  def reconcile_merge_request_ci(issue_iid) when is_binary(issue_iid) do
    with {:ok, stage4_snapshot} <- fetch_stage4_snapshot(issue_iid),
         merge_request_iid when is_binary(merge_request_iid) <-
           Map.get(stage4_snapshot, "merge_request_iid") || {:ok, :no_merge_request},
         {:ok, pipelines} <- Adapter.fetch_merge_request_pipelines(merge_request_iid) do
      case select_newest_relevant_pipeline(pipelines, stage4_snapshot) do
        {:ok, :no_pipeline} ->
          {:ok, :no_pipeline}

        {:ok, selected_pipeline} ->
          with {:ok, observation} <- build_ci_observation(issue_iid, stage4_snapshot, selected_pipeline),
               observation_map = stringify_map(Map.from_struct(observation)),
               :ok <- emit_ci_observed_audit(observation_map),
               :ok <- StateStore.record_ci_observation(issue_iid, observation_map),
               :ok <- write_ci_status_comment(issue_iid, observation),
               :ok <-
                 StateStore.record_ci_observation(issue_iid, %{
                   last_writeback_status_class: observation.status_class
                 }) do
            {:ok, observation_map}
          end
      end
    else
      {:ok, :no_merge_request} ->
        {:ok, :no_merge_request}

      {:error, _reason} = error ->
        error
    end
  end

  defp do_finalize_dry_run(%Issue{id: issue_iid} = issue, workspace_path, opts)
       when is_binary(issue_iid) do
    with {:ok, canonical_workspace} <- validate_workspace_root(workspace_path),
         {:ok, manifest_result} <- load_manifest(canonical_workspace),
         {:ok, issue_run} <- StateStore.fetch_issue_run_snapshot(issue_iid) do
      run_fingerprint = run_fingerprint(issue_iid, canonical_workspace)
      issue_run_stage4 = get_in(issue_run || %{}, ["stage4"]) || %{}

      case manifest_result do
        :missing ->
          plan =
            no_op_plan(
              issue,
              run_fingerprint,
              branch_name(issue_iid, run_fingerprint),
              "manifest-missing"
            )

          persist_dry_run_plan(issue_iid, canonical_workspace, plan)

        {:manifest, manifest} ->
          Audit.emit("artifact_manifest.loaded", %{issue_iid: issue_iid, manifest_version: manifest["version"]})

          result =
            with {:ok, normalized_manifest} <- validate_manifest(manifest),
                 {:ok, collected} <- collect_artifacts(canonical_workspace, normalized_manifest, opts),
                 {:ok, plan} <- build_plan(issue, run_fingerprint, normalized_manifest, collected, opts),
                 :ok <- ensure_digest_compatibility(issue_iid, issue_run_stage4, plan),
                 {:ok, {_plan_status, ^plan}} <- persist_dry_run_plan(issue_iid, canonical_workspace, plan),
                 :ok <- Audit.update_trace(issue_iid, %{run_fingerprint: plan.run_fingerprint}),
                 :ok <- emit_plan_audit(plan) do
              if plan.no_op do
                {:ok, {:noop, plan}}
              else
                {:ok, {:planned, plan}}
              end
            end

          case result do
            {:error, reason} = error ->
              Audit.emit("artifact_manifest.rejected", %{issue_iid: issue_iid, reason: inspect(reason)}, level: :warning)
              error

            other ->
              other
          end
      end
    end
  end

  defp maybe_execute_live_plan(_issue, {:noop, plan}, _opts), do: {:ok, {:noop, plan}}

  defp maybe_execute_live_plan(issue, {:planned, plan}, opts) do
    case live_mutation_guard(issue, opts) do
      :enabled ->
        execute_live_plan(issue, plan, opts)

      {:disabled, reason} ->
        Logger.info("Stage 4 live mutation disabled issue_id=#{issue.id} reason=#{inspect(reason)}")
        Audit.emit("live_mutation.blocked", %{issue_iid: issue.id, reason: inspect(reason)})
        {:ok, {:planned, plan}}

      {:error, reason} ->
        _ =
          StateStore.record_issue_run_snapshot(issue.id, %{
            stage4_status: "live-mutation-blocked",
            dry_run: true,
            live_mutation_enabled: false,
            live_mutation_guard_reason: inspect(reason)
          })

        Audit.emit("live_mutation.blocked", %{issue_iid: issue.id, reason: inspect(reason)}, level: :warning)
        {:error, reason}
    end
  end

  defp live_mutation_guard(%Issue{}, opts) when is_list(opts) do
    tracker = Keyword.get(opts, :tracker_settings) || Config.settings!().tracker
    project_slug = tracker.project_slug
    live_mutation? = tracker.stage4_live_mutation == true
    allowed_project_slugs = tracker.stage4_allowed_project_slugs || []

    cond do
      tracker.kind != "gitlab" ->
        {:disabled, :non_gitlab_tracker}

      not live_mutation? ->
        {:disabled, :live_mutation_disabled}

      not is_binary(project_slug) or project_slug == "" ->
        {:error, :missing_gitlab_project_slug}

      project_slug not in allowed_project_slugs ->
        {:error, {:stage4_live_project_not_allowlisted, project_slug}}

      true ->
        :enabled
    end
  end

  defp execute_live_plan(%Issue{id: issue_iid}, plan, opts)
       when is_binary(issue_iid) and is_map(plan) and is_list(opts) do
    with :ok <- validate_live_provenance(issue_iid, plan),
         :ok <- record_live_execution_start(issue_iid, plan),
         :ok <- reconcile_remote_mutation_state(issue_iid, plan),
         :ok <- Adapter.create_branch_once(issue_iid, plan.run_fingerprint, plan.source_branch, plan.target_branch),
         :ok <- emit_branch_audit(issue_iid),
         :ok <-
           Adapter.create_commit_once(
             issue_iid,
             plan.run_fingerprint,
             plan.source_branch,
             plan.commit_message,
             plan.commit_actions,
             manifest_digest: plan.manifest_digest,
             action_digest: plan.action_digest
           ),
         :ok <- emit_commit_audit(issue_iid),
         :ok <-
           Adapter.create_merge_request_once(
             issue_iid,
             plan.run_fingerprint,
             plan.source_branch,
             plan.target_branch,
             plan.merge_request_title,
             plan.merge_request_description
           ),
         :ok <- emit_merge_request_audit(issue_iid),
         {:ok, stage4_snapshot} <- fetch_stage4_snapshot(issue_iid),
         merge_request_url when is_binary(merge_request_url) <-
           Map.get(stage4_snapshot, "merge_request_url") || {:error, :missing_merge_request_url},
         :ok <-
           write_merge_request_link_comment(
             issue_iid,
             plan.run_fingerprint,
             merge_request_url,
             plan.source_branch
           ),
         :ok <-
           StateStore.record_issue_run_snapshot(issue_iid, %{
             stage4_status: "live-mr-created",
             dry_run: false,
             live_mutation_enabled: true
           }),
         {:ok, updated_stage4_snapshot} <- fetch_stage4_snapshot(issue_iid) do
      Logger.info("Executed Stage 4 live mutation issue_id=#{issue_iid} branch=#{plan.source_branch} mr_url=#{merge_request_url}")

      {:ok, {:executed, plan, updated_stage4_snapshot}}
    else
      {:error, reason} = error ->
        Audit.emit("error.recorded", %{issue_iid: issue_iid, reason: inspect(reason)}, level: :warning)

        _ =
          StateStore.record_issue_run_snapshot(issue_iid, %{
            stage4_status: "live-mutation-error",
            dry_run: false,
            live_mutation_enabled: true,
            stage4_error: inspect(reason)
          })

        error
    end
  end

  defp validate_live_provenance(issue_iid, plan) when is_binary(issue_iid) and is_map(plan) do
    with {:ok, stage4_snapshot} <- fetch_stage4_snapshot(issue_iid) do
      cond do
        Map.get(stage4_snapshot, "branch_name") not in [nil, "", plan.branch_name] ->
          {:error, {:live_mutation_conflict, issue_iid, %{existing_branch_name: Map.get(stage4_snapshot, "branch_name"), next_branch_name: plan.branch_name}}}

        Map.get(stage4_snapshot, "run_fingerprint") not in [nil, "", plan.run_fingerprint] ->
          {:error,
           {:live_mutation_conflict, issue_iid,
            %{
              existing_run_fingerprint: Map.get(stage4_snapshot, "run_fingerprint"),
              next_run_fingerprint: plan.run_fingerprint
            }}}

        Map.get(stage4_snapshot, "manifest_digest") not in [nil, plan.manifest_digest] ->
          {:error,
           {:live_mutation_conflict, issue_iid,
            %{
              existing_manifest_digest: Map.get(stage4_snapshot, "manifest_digest"),
              next_manifest_digest: plan.manifest_digest
            }}}

        Map.get(stage4_snapshot, "action_digest") not in [nil, plan.action_digest] ->
          {:error,
           {:live_mutation_conflict, issue_iid,
            %{
              existing_action_digest: Map.get(stage4_snapshot, "action_digest"),
              next_action_digest: plan.action_digest
            }}}

        true ->
          :ok
      end
    end
  end

  defp record_live_execution_start(issue_iid, plan) when is_binary(issue_iid) and is_map(plan) do
    StateStore.record_issue_run_snapshot(issue_iid, %{
      stage4_status: "live-mutation-started",
      dry_run: false,
      live_mutation_enabled: true,
      run_fingerprint: plan.run_fingerprint,
      branch_name: plan.branch_name,
      target_branch: plan.target_branch,
      manifest_digest: plan.manifest_digest,
      collected_artifact_digest: plan.collected_artifact_digest,
      action_digest: plan.action_digest,
      commit_message: plan.commit_message,
      merge_request_title: plan.merge_request_title,
      no_op: plan.no_op
    })
  end

  defp reconcile_remote_mutation_state(issue_iid, plan)
       when is_binary(issue_iid) and is_map(plan) do
    with {:ok, source_branch} <- Adapter.fetch_branch(plan.source_branch),
         {:ok, target_branch} <- Adapter.fetch_branch(plan.target_branch),
         {:ok, merge_request} <- Adapter.fetch_open_merge_request(plan.source_branch, nil) do
      cond do
        is_map(merge_request) ->
          reconcile_remote_merge_request(issue_iid, plan, source_branch, merge_request)

        is_map(source_branch) ->
          reconcile_remote_branch(issue_iid, plan, source_branch, target_branch)

        true ->
          :ok
      end
    end
  end

  defp reconcile_remote_merge_request(issue_iid, plan, source_branch, merge_request)
       when is_binary(issue_iid) and is_map(plan) and is_map(merge_request) do
    cond do
      not is_map(source_branch) ->
        Audit.emit("branch.rejected", %{issue_iid: issue_iid, source_branch: plan.source_branch, reason: "missing_source_branch"}, level: :warning)
        {:error, {:remote_merge_request_missing_source_branch, issue_iid, plan.source_branch}}

      Map.get(merge_request, "target_branch") != plan.target_branch ->
        Audit.emit(
          "mr.rejected",
          %{issue_iid: issue_iid, source_branch: plan.source_branch, expected_target_branch: plan.target_branch, existing_target_branch: Map.get(merge_request, "target_branch")},
          level: :warning
        )

        {:error,
         {:unexpected_existing_merge_request_target_branch, issue_iid,
          %{
            source_branch: plan.source_branch,
            expected_target_branch: plan.target_branch,
            existing_target_branch: Map.get(merge_request, "target_branch"),
            merge_request_iid: Map.get(merge_request, "merge_request_iid")
          }}}

      Map.get(merge_request, "title") != plan.merge_request_title ->
        Audit.emit("mr.rejected", %{issue_iid: issue_iid, source_branch: plan.source_branch, reason: "title_mismatch"}, level: :warning)

        {:error,
         {:remote_merge_request_provenance_mismatch, issue_iid,
          %{
            merge_request_iid: Map.get(merge_request, "merge_request_iid"),
            expected_title: plan.merge_request_title,
            existing_title: Map.get(merge_request, "title")
          }}}

      normalize_multiline(Map.get(merge_request, "description")) !=
          normalize_multiline(plan.merge_request_description) ->
        Audit.emit("mr.rejected", %{issue_iid: issue_iid, source_branch: plan.source_branch, reason: "description_mismatch"}, level: :warning)

        {:error,
         {:remote_merge_request_provenance_mismatch, issue_iid,
          %{
            merge_request_iid: Map.get(merge_request, "merge_request_iid"),
            expected_description_digest: short_digest(plan.action_digest),
            existing_description: "mismatch"
          }}}

      true ->
        with :ok <- record_recovered_branch(issue_iid, plan, source_branch),
             :ok <- record_recovered_commit(issue_iid, plan, source_branch),
             :ok <- record_recovered_merge_request(issue_iid, plan, merge_request),
             :ok <- emit_branch_audit(issue_iid),
             :ok <- emit_commit_audit(issue_iid),
             :ok <- emit_merge_request_audit(issue_iid) do
          :ok
        end
    end
  end

  defp reconcile_remote_branch(issue_iid, plan, source_branch, target_branch)
       when is_binary(issue_iid) and is_map(plan) and is_map(source_branch) do
    cond do
      branch_matches_target_head?(source_branch, target_branch) ->
        with :ok <- record_recovered_branch(issue_iid, plan, source_branch),
             :ok <- emit_branch_audit(issue_iid) do
          :ok
        end

      branch_matches_expected_commit?(source_branch, plan) ->
        with :ok <- record_recovered_branch(issue_iid, plan, source_branch),
             :ok <- record_recovered_commit(issue_iid, plan, source_branch),
             :ok <- emit_branch_audit(issue_iid),
             :ok <- emit_commit_audit(issue_iid) do
          :ok
        end

      true ->
        Audit.emit("branch.rejected", %{issue_iid: issue_iid, source_branch: plan.source_branch, reason: "provenance_mismatch"}, level: :warning)

        {:error,
         {:remote_branch_provenance_mismatch, issue_iid,
          %{
            source_branch: plan.source_branch,
            target_branch: plan.target_branch,
            branch_commit_id: Map.get(source_branch, "commit_id"),
            target_commit_id: if(is_map(target_branch), do: Map.get(target_branch, "commit_id"), else: nil),
            expected_commit_provenance: commit_provenance_token(plan)
          }}}
    end
  end

  defp branch_matches_target_head?(source_branch, target_branch)
       when is_map(source_branch) and is_map(target_branch) do
    source_commit_id = Map.get(source_branch, "commit_id")
    target_commit_id = Map.get(target_branch, "commit_id")
    is_binary(source_commit_id) and source_commit_id != "" and source_commit_id == target_commit_id
  end

  defp branch_matches_target_head?(_source_branch, _target_branch), do: false

  defp branch_matches_expected_commit?(source_branch, plan)
       when is_map(source_branch) and is_map(plan) do
    token = commit_provenance_token(plan)

    [Map.get(source_branch, "commit_title"), Map.get(source_branch, "commit_message")]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(fn value ->
      String.contains?(value, token) or normalize_multiline(value) == normalize_multiline(plan.commit_message)
    end)
  end

  defp record_recovered_branch(issue_iid, plan, source_branch)
       when is_binary(issue_iid) and is_map(plan) and is_map(source_branch) do
    Adapter.record_existing_branch_once(
      issue_iid,
      plan.run_fingerprint,
      plan.source_branch,
      plan.target_branch,
      %{
        "branch_name" => plan.source_branch,
        "commit_id" => Map.get(source_branch, "commit_id")
      }
    )
  end

  defp record_recovered_commit(issue_iid, plan, source_branch)
       when is_binary(issue_iid) and is_map(plan) and is_map(source_branch) do
    commit_opts = [
      manifest_digest: plan.manifest_digest,
      action_digest: plan.action_digest
    ]

    Adapter.record_existing_commit_once(
      issue_iid,
      plan.run_fingerprint,
      plan.source_branch,
      plan.commit_message,
      commit_opts,
      %{
        "commit_sha" => Map.get(source_branch, "commit_id"),
        "title" => Map.get(source_branch, "commit_title"),
        "message" => Map.get(source_branch, "commit_message")
      }
    )
  end

  defp record_recovered_merge_request(issue_iid, plan, merge_request)
       when is_binary(issue_iid) and is_map(plan) and is_map(merge_request) do
    Adapter.record_existing_merge_request_once(
      issue_iid,
      plan.run_fingerprint,
      plan.source_branch,
      plan.target_branch,
      plan.merge_request_title,
      %{
        "merge_request_iid" => Map.get(merge_request, "merge_request_iid"),
        "merge_request_url" => Map.get(merge_request, "merge_request_url"),
        "source_branch" => Map.get(merge_request, "source_branch"),
        "target_branch" => Map.get(merge_request, "target_branch"),
        "title" => Map.get(merge_request, "title"),
        "description" => Map.get(merge_request, "description"),
        "sha" => Map.get(merge_request, "sha")
      }
    )
  end

  defp fetch_stage4_snapshot(issue_iid) when is_binary(issue_iid) do
    case StateStore.fetch_issue_run_snapshot(issue_iid) do
      {:ok, issue_run} -> {:ok, get_in(issue_run || %{}, ["stage4"]) || %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defmodule CiObservation do
    @moduledoc false
    @enforce_keys [
      :issue_iid,
      :run_fingerprint,
      :merge_request_iid,
      :merge_request_url,
      :pipeline_id,
      :pipeline_status,
      :status_class,
      :ci_observed_at
    ]
    defstruct [
      :issue_iid,
      :run_fingerprint,
      :merge_request_iid,
      :merge_request_url,
      :pipeline_id,
      :pipeline_status,
      :status_class,
      :ci_observed_at
    ]
  end

  defp select_newest_relevant_pipeline([], _stage4_snapshot), do: {:ok, :no_pipeline}

  defp select_newest_relevant_pipeline(pipelines, stage4_snapshot) when is_list(pipelines) and is_map(stage4_snapshot) do
    source_branch = Map.get(stage4_snapshot, "source_branch")

    pipelines
    |> Enum.filter(fn pipeline ->
      is_nil(source_branch) or source_branch == "" or pipeline["ref"] in [nil, "", source_branch]
    end)
    |> case do
      [] ->
        {:ok, :no_pipeline}

      relevant_pipelines ->
        selected =
          Enum.max_by(relevant_pipelines, fn pipeline ->
            {parse_pipeline_timestamp(pipeline["updated_at"]), pipeline["id"] || 0}
          end)

        {:ok, selected}
    end
  end

  defp build_ci_observation(issue_iid, stage4_snapshot, pipeline)
       when is_binary(issue_iid) and is_map(stage4_snapshot) and is_map(pipeline) do
    merge_request_iid = Map.get(stage4_snapshot, "merge_request_iid")
    merge_request_url = Map.get(stage4_snapshot, "merge_request_url")
    run_fingerprint = Map.get(stage4_snapshot, "run_fingerprint")
    pipeline_status = normalize_pipeline_status(Map.get(pipeline, "status"))

    if is_binary(merge_request_iid) and is_binary(merge_request_url) and is_binary(run_fingerprint) do
      {:ok,
       %CiObservation{
         issue_iid: issue_iid,
         run_fingerprint: run_fingerprint,
         merge_request_iid: merge_request_iid,
         merge_request_url: merge_request_url,
         pipeline_id: to_string(Map.get(pipeline, "id")),
         pipeline_status: pipeline_status,
         status_class: pipeline_status_class(pipeline_status),
         ci_observed_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    else
      {:error, :missing_merge_request_snapshot}
    end
  end

  defp write_ci_status_comment(issue_iid, %CiObservation{} = observation) when is_binary(issue_iid) do
    body =
      "Symphony observed CI status `#{observation.pipeline_status}` for merge request " <>
        "#{observation.merge_request_url} on pipeline `#{observation.pipeline_id}`."

    result =
      Adapter.create_comment_once(
        issue_iid,
        "mr:#{observation.merge_request_iid}:pipeline:#{observation.pipeline_id}:#{observation.status_class}",
        body,
        %{
          run_fingerprint: observation.run_fingerprint,
          merge_request_iid: observation.merge_request_iid,
          merge_request_url: observation.merge_request_url,
          pipeline_id: observation.pipeline_id,
          pipeline_status: observation.pipeline_status,
          status_class: observation.status_class,
          ci_observed_at: observation.ci_observed_at,
          last_writeback_status_class: observation.status_class
        }
      )

    if result == :ok do
      Audit.emit("ci_comment.written", %{
        issue_iid: issue_iid,
        merge_request_iid: observation.merge_request_iid,
        pipeline_id: observation.pipeline_id,
        pipeline_status: observation.pipeline_status,
        status_class: observation.status_class
      })
    end

    result
  end

  defp normalize_pipeline_status(status) when is_binary(status) do
    normalized = String.downcase(String.trim(status))

    cond do
      MapSet.member?(@ci_pending_statuses, normalized) -> "pending"
      MapSet.member?(@ci_running_statuses, normalized) -> "running"
      MapSet.member?(@ci_success_statuses, normalized) -> "success"
      MapSet.member?(@ci_failure_statuses, normalized) -> normalized
      MapSet.member?(@ci_unknown_statuses, normalized) -> normalized
      true -> "unknown"
    end
  end

  defp normalize_pipeline_status(_status), do: "unknown"

  defp pipeline_status_class(status) when status in ["pending"], do: "ci-pending"
  defp pipeline_status_class(status) when status in ["running"], do: "ci-running"
  defp pipeline_status_class(status) when status in ["success"], do: "ci-success"
  defp pipeline_status_class(status) when status in ["failed", "canceled"], do: "ci-failure"
  defp pipeline_status_class(_status), do: "ci-unknown"

  defp parse_pipeline_timestamp(nil), do: 0

  defp parse_pipeline_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> DateTime.to_unix(parsed, :microsecond)
      _ -> 0
    end
  end

  defp validate_workspace_root(nil), do: {:error, :missing_workspace_path}

  defp validate_workspace_root(workspace_path) when is_binary(workspace_path) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace_path),
         true <- File.dir?(canonical_workspace) or {:error, {:workspace_not_found, canonical_workspace}} do
      {:ok, canonical_workspace}
    end
  end

  defp load_manifest(canonical_workspace) when is_binary(canonical_workspace) do
    manifest_path = Path.join(canonical_workspace, @manifest_relpath)

    case File.read(manifest_path) do
      {:ok, raw_manifest} ->
        case Jason.decode(raw_manifest) do
          {:ok, manifest} when is_map(manifest) -> {:ok, {:manifest, manifest}}
          {:ok, _other} -> {:error, {:invalid_artifact_manifest, :not_a_map}}
          {:error, reason} -> {:error, {:invalid_artifact_manifest_json, inspect(reason)}}
        end

      {:error, :enoent} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, {:artifact_manifest_read_failed, manifest_path, reason}}
    end
  end

  defp validate_manifest(%{"version" => @manifest_version, "artifacts" => artifacts})
       when is_list(artifacts) do
    normalized =
      artifacts
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {artifact, index}, {:ok, acc} ->
        case validate_artifact_entry(artifact, index) do
          {:ok, normalized_artifact} -> {:cont, {:ok, acc ++ [normalized_artifact]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case normalized do
      {:ok, normalized_artifacts} ->
        {:ok,
         %{
           version: @manifest_version,
           artifacts: normalized_artifacts
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_manifest(%{"version" => version}) when version != @manifest_version do
    {:error, {:unsupported_artifact_manifest_version, version}}
  end

  defp validate_manifest(_manifest), do: {:error, :invalid_artifact_manifest}

  defp validate_artifact_entry(%{} = artifact, index) do
    repository_path = Map.get(artifact, "repository_path")
    workspace_source_path = Map.get(artifact, "workspace_source_path")
    action = Map.get(artifact, "action")

    cond do
      not is_binary(repository_path) or String.trim(repository_path) == "" ->
        {:error, {:invalid_artifact_entry, index, :missing_repository_path}}

      not is_binary(workspace_source_path) or String.trim(workspace_source_path) == "" ->
        {:error, {:invalid_artifact_entry, index, :missing_workspace_source_path}}

      action not in ["create", "update"] ->
        {:error, {:invalid_artifact_entry, index, :unsupported_action}}

      true ->
        {:ok,
         %{
           repository_path: String.trim(repository_path),
           workspace_source_path: String.trim(workspace_source_path),
           action: action,
           description: optional_trimmed_string(Map.get(artifact, "description")),
           content_type: optional_trimmed_string(Map.get(artifact, "content_type")),
           metadata: normalize_metadata(Map.get(artifact, "metadata"))
         }}
    end
  end

  defp collect_artifacts(canonical_workspace, manifest, opts)
       when is_binary(canonical_workspace) and is_map(manifest) and is_list(opts) do
    allowed_repo_prefixes = Keyword.get(opts, :allowed_repo_prefixes, @allowed_repo_prefixes)
    max_artifact_bytes = Keyword.get(opts, :max_artifact_bytes, @max_artifact_bytes)
    allow_binary_artifacts = Keyword.get(opts, :allow_binary_artifacts, false)

    manifest.artifacts
    |> Enum.reduce_while({:ok, []}, fn artifact, {:ok, acc} ->
      with :ok <- validate_declared_paths(artifact, allowed_repo_prefixes),
           {:ok, canonical_source_path} <-
             resolve_workspace_source_path(canonical_workspace, artifact.workspace_source_path),
           {:ok, content} <-
             read_artifact_content(canonical_source_path, artifact, max_artifact_bytes, allow_binary_artifacts) do
        collected_artifact =
          Map.put(artifact, :content, content)

        {:cont, {:ok, acc ++ [collected_artifact]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_declared_paths(artifact, allowed_repo_prefixes) do
    with :ok <- validate_relative_path(:repository_path, artifact.repository_path),
         :ok <- validate_relative_path(:workspace_source_path, artifact.workspace_source_path),
         :ok <- reject_blocked_repo_path(artifact.repository_path),
         :ok <- reject_blocked_repo_path(artifact.workspace_source_path),
         :ok <- validate_allowed_repo_path(artifact.repository_path, allowed_repo_prefixes) do
      :ok
    end
  end

  defp validate_relative_path(_field, path) when not is_binary(path), do: {:error, :invalid_artifact_path}

  defp validate_relative_path(field, path) do
    cond do
      Path.type(path) == :absolute ->
        {:error, {field, :absolute_path_rejected, path}}

      path == "." or path == "" ->
        {:error, {field, :empty_path_rejected, path}}

      Enum.any?(Path.split(path), &(&1 == "..")) ->
        {:error, {field, :path_traversal_rejected, path}}

      true ->
        :ok
    end
  end

  defp reject_blocked_repo_path(path) when is_binary(path) do
    downcased = String.downcase(path)
    segments = Path.split(downcased)

    cond do
      Enum.any?(@blocked_path_segments, &(&1 in segments)) ->
        {:error, {:blocked_path_segment, path}}

      Enum.any?(@blocked_path_suffixes, &String.ends_with?(downcased, &1)) ->
        {:error, {:blocked_path_suffix, path}}

      Enum.any?(@blocked_path_substrings, &String.contains?(downcased, &1)) ->
        {:error, {:blocked_path_substring, path}}

      true ->
        :ok
    end
  end

  defp validate_allowed_repo_path(path, allowed_repo_prefixes) when is_binary(path) do
    if path in @allowed_repo_exact or Enum.any?(allowed_repo_prefixes, &String.starts_with?(path, &1)) do
      :ok
    else
      {:error, {:disallowed_repo_path, path}}
    end
  end

  defp resolve_workspace_source_path(canonical_workspace, source_relpath)
       when is_binary(canonical_workspace) and is_binary(source_relpath) do
    source_path = Path.join(canonical_workspace, source_relpath)

    with {:ok, canonical_source_path} <- PathSafety.canonicalize(source_path),
         :ok <- ensure_path_inside_workspace(canonical_workspace, canonical_source_path),
         true <- File.regular?(canonical_source_path) or {:error, {:artifact_source_missing, source_relpath}} do
      {:ok, canonical_source_path}
    end
  end

  defp ensure_path_inside_workspace(canonical_workspace, canonical_source_path) do
    workspace_prefix = String.trim_trailing(canonical_workspace, "/") <> "/"

    cond do
      canonical_source_path == canonical_workspace ->
        {:error, {:artifact_source_is_workspace_root, canonical_source_path}}

      String.starts_with?(canonical_source_path <> "/", workspace_prefix) ->
        :ok

      true ->
        {:error, {:artifact_source_outside_workspace, canonical_source_path, canonical_workspace}}
    end
  end

  defp read_artifact_content(canonical_source_path, artifact, max_artifact_bytes, allow_binary_artifacts)
       when is_binary(canonical_source_path) and is_map(artifact) do
    case File.stat(canonical_source_path) do
      {:ok, %File.Stat{size: size}} when size > max_artifact_bytes ->
        {:error, {:artifact_too_large, artifact.workspace_source_path, size, max_artifact_bytes}}

      {:ok, %File.Stat{}} ->
        with {:ok, content} <- File.read(canonical_source_path),
             :ok <- validate_artifact_content(content, artifact, allow_binary_artifacts) do
          {:ok, content}
        end

      {:error, reason} ->
        {:error, {:artifact_stat_failed, canonical_source_path, reason}}
    end
  end

  defp validate_artifact_content(content, artifact, allow_binary_artifacts) when is_binary(content) do
    content_type = artifact.content_type
    binary_content? = String.contains?(content, <<0>>) or not String.valid?(content)

    cond do
      binary_content? and allow_binary_artifacts and explicit_binary_allowed?(artifact) ->
        :ok

      binary_content? ->
        {:error, {:unsupported_binary_artifact, artifact.workspace_source_path}}

      is_binary(content_type) and content_type not in @allowed_text_content_types and
          not String.starts_with?(content_type, "text/") ->
        {:error, {:unsupported_content_type, artifact.workspace_source_path, content_type}}

      true ->
        :ok
    end
  end

  defp explicit_binary_allowed?(artifact) when is_map(artifact) do
    artifact.metadata["allow_binary"] == true
  end

  defp build_plan(issue, run_fingerprint, manifest, collected_artifacts, opts)
       when is_map(manifest) and is_list(collected_artifacts) and is_list(opts) do
    issue_iid = issue.id
    source_branch = branch_name(issue_iid, run_fingerprint)
    target_branch = Keyword.get(opts, :target_branch, @default_target_branch)
    commit_actions = Enum.map(collected_artifacts, &to_commit_action/1)
    manifest_digest = digest_manifest(manifest)
    collected_artifact_digest = digest_collected_artifacts(collected_artifacts)
    action_digest = digest_commit_actions(commit_actions)
    no_op = commit_actions == []
    commit_message = stage4_commit_message(issue_iid, run_fingerprint, action_digest)
    merge_request_title = "Issue ##{issue_iid}: #{issue.title || "Generated update"}"

    merge_request_description =
      [
        "Generated by Symphony dry-run planning.",
        "",
        "- Issue: #{issue.identifier || "##{issue_iid}"}",
        "- Manifest digest: `#{manifest_digest}`",
        "- Action digest: `#{action_digest}`"
      ]
      |> Enum.join("\n")

    {:ok,
     %{
       issue_iid: issue_iid,
       run_fingerprint: run_fingerprint,
       source_branch: source_branch,
       target_branch: target_branch,
       commit_message: commit_message,
       merge_request_title: merge_request_title,
       merge_request_description: merge_request_description,
       commit_actions: commit_actions,
       manifest_digest: manifest_digest,
       collected_artifact_digest: collected_artifact_digest,
       action_digest: action_digest,
       branch_name: source_branch,
       would_create_branch: not no_op,
       would_create_commit: not no_op,
       would_create_merge_request: not no_op,
       no_op: no_op
     }}
  end

  defp no_op_plan(issue, run_fingerprint, source_branch, reason) do
    %{
      issue_iid: issue.id,
      run_fingerprint: run_fingerprint,
      source_branch: source_branch,
      target_branch: @default_target_branch,
      commit_message: "chore(gitlab): no-op for issue ##{issue.id}",
      merge_request_title: "Issue ##{issue.id}: no artifact changes",
      merge_request_description: "Dry-run finalization produced no repository artifacts (#{reason}).",
      commit_actions: [],
      manifest_digest: nil,
      collected_artifact_digest: nil,
      action_digest: nil,
      branch_name: source_branch,
      would_create_branch: false,
      would_create_commit: false,
      would_create_merge_request: false,
      no_op: true
    }
  end

  defp ensure_digest_compatibility(_issue_iid, stage4_snapshot, _plan)
       when map_size(stage4_snapshot) == 0,
       do: :ok

  defp ensure_digest_compatibility(issue_iid, stage4_snapshot, plan)
       when is_binary(issue_iid) and is_map(stage4_snapshot) and is_map(plan) do
    previous_run_fingerprint = Map.get(stage4_snapshot, "run_fingerprint")
    previous_manifest_digest = Map.get(stage4_snapshot, "manifest_digest")
    previous_action_digest = Map.get(stage4_snapshot, "action_digest")

    cond do
      previous_run_fingerprint in [nil, "", plan.run_fingerprint] and
        previous_manifest_digest in [nil, plan.manifest_digest] and
          previous_action_digest in [nil, plan.action_digest] ->
        :ok

      previous_run_fingerprint == plan.run_fingerprint ->
        {:error,
         {:dry_run_conflict, issue_iid,
          %{
            previous_manifest_digest: previous_manifest_digest,
            previous_action_digest: previous_action_digest,
            next_manifest_digest: plan.manifest_digest,
            next_action_digest: plan.action_digest
          }}}

      true ->
        :ok
    end
  end

  defp stage4_commit_message(issue_iid, run_fingerprint, action_digest)
       when is_binary(issue_iid) and is_binary(run_fingerprint) and is_binary(action_digest) do
    "chore(gitlab): update issue ##{issue_iid} artifacts #{commit_provenance_token(run_fingerprint, action_digest)}"
  end

  defp commit_provenance_token(%{} = plan) do
    commit_provenance_token(plan.run_fingerprint, plan.action_digest)
  end

  defp commit_provenance_token(run_fingerprint, action_digest)
       when is_binary(run_fingerprint) and is_binary(action_digest) do
    "[stage4:#{sanitize_branch_component(run_fingerprint)}:#{short_digest(action_digest)}]"
  end

  defp short_digest(digest) when is_binary(digest) do
    digest
    |> String.replace(~r/[^[:alnum:]]/u, "")
    |> String.slice(0, 12)
  end

  defp normalize_multiline(nil), do: nil
  defp normalize_multiline(value) when is_binary(value), do: value |> String.replace("\r\n", "\n") |> String.trim()

  defp emit_plan_audit(plan) when is_map(plan) do
    :ok = ensure_trace_context(plan.issue_iid, plan.run_fingerprint)

    Audit.emit("mr_plan.created", %{
      issue_iid: plan.issue_iid,
      run_fingerprint: plan.run_fingerprint,
      source_branch: plan.source_branch,
      target_branch: plan.target_branch,
      manifest_digest: plan.manifest_digest,
      action_digest: plan.action_digest,
      no_op: plan.no_op
    })
  end

  defp ensure_trace_context(issue_iid, run_fingerprint)
       when is_binary(issue_iid) and is_binary(run_fingerprint) do
    case Audit.context(issue_iid) do
      %{"trace_id" => trace_id, "run_id" => run_id}
      when is_binary(trace_id) and trace_id != "" and is_binary(run_id) and run_id != "" ->
        :ok

      _ ->
        with {:ok, _context} <-
               Audit.start_trace(issue_iid, "stage4:#{run_fingerprint}", %{run_fingerprint: run_fingerprint, source: "gitlab"}) do
          :ok
        else
          {:error, _reason} -> :ok
        end
    end
  end

  defp emit_ci_observed_audit(observation_map) when is_map(observation_map) do
    Audit.emit("ci_pipeline.observed", observation_map)
  end

  defp emit_branch_audit(issue_iid) when is_binary(issue_iid) do
    with {:ok, snapshot} <- fetch_stage4_snapshot(issue_iid) do
      status = Map.get(snapshot, "branch_status") || "created"

      Audit.emit("branch.#{status}", %{
        issue_iid: issue_iid,
        run_fingerprint: Map.get(snapshot, "run_fingerprint"),
        source_branch: Map.get(snapshot, "branch_name"),
        target_ref: Map.get(snapshot, "target_ref")
      })
    end
  end

  defp emit_commit_audit(issue_iid) when is_binary(issue_iid) do
    with {:ok, snapshot} <- fetch_stage4_snapshot(issue_iid) do
      status = Map.get(snapshot, "commit_status") || "created"

      Audit.emit("commit.#{status}", %{
        issue_iid: issue_iid,
        run_fingerprint: Map.get(snapshot, "run_fingerprint"),
        source_branch: Map.get(snapshot, "branch_name"),
        commit_sha: Map.get(snapshot, "commit_sha")
      })
    end
  end

  defp emit_merge_request_audit(issue_iid) when is_binary(issue_iid) do
    with {:ok, snapshot} <- fetch_stage4_snapshot(issue_iid) do
      status = Map.get(snapshot, "merge_request_status") || "created"

      Audit.emit("mr.#{status}", %{
        issue_iid: issue_iid,
        run_fingerprint: Map.get(snapshot, "run_fingerprint"),
        source_branch: Map.get(snapshot, "source_branch") || Map.get(snapshot, "branch_name"),
        target_branch: Map.get(snapshot, "target_branch"),
        merge_request_iid: Map.get(snapshot, "merge_request_iid"),
        merge_request_url: Map.get(snapshot, "merge_request_url")
      })
    end
  end

  defp persist_dry_run_plan(issue_iid, canonical_workspace, plan)
       when is_binary(issue_iid) and is_binary(canonical_workspace) and is_map(plan) do
    StateStore.record_issue_run_snapshot(issue_iid, %{
      stage4_status: if(plan.no_op, do: "no-op", else: "dry-run-planned"),
      dry_run: true,
      workspace_path: canonical_workspace,
      run_fingerprint: plan.run_fingerprint,
      branch_name: plan.branch_name,
      target_branch: plan.target_branch,
      manifest_digest: plan.manifest_digest,
      collected_artifact_digest: plan.collected_artifact_digest,
      action_digest: plan.action_digest,
      commit_message: plan.commit_message,
      merge_request_title: plan.merge_request_title,
      no_op: plan.no_op,
      commit_actions: Enum.map(plan.commit_actions, &stringify_map/1)
    })
    |> case do
      :ok ->
        if plan.no_op do
          {:ok, {:noop, plan}}
        else
          {:ok, {:planned, plan}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_commit_action(collected_artifact) do
    %{
      action: collected_artifact.action,
      file_path: collected_artifact.repository_path,
      content: collected_artifact.content
    }
  end

  defp digest_manifest(manifest) when is_map(manifest), do: digest_term(manifest)
  defp digest_collected_artifacts(collected_artifacts) when is_list(collected_artifacts), do: digest_term(collected_artifacts)
  defp digest_commit_actions(commit_actions) when is_list(commit_actions), do: digest_term(commit_actions)

  defp digest_term(term) do
    term
    |> normalize_for_digest()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_for_digest(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} -> {to_string(key), normalize_for_digest(nested_value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.into(%{})
  end

  defp normalize_for_digest(value) when is_list(value), do: Enum.map(value, &normalize_for_digest/1)
  defp normalize_for_digest(value), do: value

  defp sanitize_branch_component(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp run_fingerprint(issue_iid, canonical_workspace) do
    digest_term(%{issue_iid: issue_iid, workspace_path: canonical_workspace})
    |> binary_part(0, 12)
  end

  defp optional_trimmed_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_trimmed_string(_value), do: nil

  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
