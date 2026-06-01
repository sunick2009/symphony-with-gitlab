defmodule SymphonyElixir.GitLab.Adapter do
  @moduledoc """
  GitLab-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, GitLab.Client, GitLab.StateStore}

  @soc_lifecycle_labels [
    "soc::queued",
    "soc::claimed",
    "soc::running",
    "soc::waiting-input",
    "soc::human-review",
    "soc::rework",
    "soc::failed",
    "soc::done"
  ]

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    client_module().post_issue_comment(issue_id, body)
  end

  @spec create_comment_once(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def create_comment_once(issue_id, comment_key, body, attrs \\ %{})
      when is_binary(issue_id) and is_binary(comment_key) and is_binary(body) and is_map(attrs) do
    operation_key = writeback_key(issue_id, "comment", comment_key)

    StateStore.writeback_once(
      operation_key,
      Map.merge(
        %{
          operation: "comment",
          issue_iid: issue_id,
          comment_key: comment_key
        },
        attrs
      ),
      fn -> create_comment(issue_id, body) end
    )
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    client_module().update_issue_labels(issue_id, [state_name], lifecycle_labels_to_remove(state_name))
  end

  @spec update_issue_state_once(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state_once(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    operation_key = writeback_key(issue_id, "transition", normalize_label(state_name))

    StateStore.writeback_once(
      operation_key,
      %{
        operation: "transition",
        issue_iid: issue_id,
        lifecycle_state: state_name
      },
      fn -> update_issue_state(issue_id, state_name) end
    )
  end

  @spec transition_issue_labels(String.t(), String.t()) :: :ok | {:error, term()}
  def transition_issue_labels(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    update_issue_state_once(issue_id, state_name)
  end

  @spec lifecycle_labels() :: [String.t()]
  def lifecycle_labels, do: @soc_lifecycle_labels

  @spec fetch_branch(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def fetch_branch(branch_name) when is_binary(branch_name) do
    client_module().fetch_branch(branch_name)
  end

  @spec create_branch_once(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_branch_once(issue_id, run_fingerprint, branch_name, ref)
      when is_binary(issue_id) and is_binary(run_fingerprint) and is_binary(branch_name) and
             is_binary(ref) do
    operation_key = writeback_key(issue_id, "branch", run_fingerprint)

    StateStore.writeback_once(
      operation_key,
      %{
        operation: "branch",
        issue_iid: issue_id,
        run_fingerprint: run_fingerprint,
        branch_name: branch_name,
        target_ref: ref
      },
      fn ->
        case fetch_branch(branch_name) do
          {:ok, nil} ->
            client_module().create_branch(branch_name, ref)
            |> with_status_metadata("branch_status", "created")

          {:ok, branch} ->
            {:ok, Map.put(branch, "branch_status", "reused")}

          {:error, reason} ->
            {:error, reason}
        end
      end
    )
  end

  @spec create_commit_once(String.t(), String.t(), String.t(), String.t(), [map()], keyword()) ::
          :ok | {:error, term()}
  def create_commit_once(issue_id, run_fingerprint, branch_name, message, actions, opts \\ [])
      when is_binary(issue_id) and is_binary(run_fingerprint) and is_binary(branch_name) and
             is_binary(message) and is_list(actions) and is_list(opts) do
    operation_key = writeback_key(issue_id, "commit", run_fingerprint)

    StateStore.writeback_once(
      operation_key,
      %{
        operation: "commit",
        issue_iid: issue_id,
        run_fingerprint: run_fingerprint,
        manifest_digest: Keyword.get(opts, :manifest_digest),
        action_digest: Keyword.get(opts, :action_digest),
        branch_name: branch_name,
        commit_message: message
      },
      fn ->
        client_module().create_commit(branch_name, message, actions, opts)
        |> with_status_metadata("commit_status", "created")
      end
    )
  end

  @spec fetch_open_merge_request(String.t(), String.t() | nil) :: {:ok, map() | nil} | {:error, term()}
  def fetch_open_merge_request(source_branch, target_branch \\ nil)
      when is_binary(source_branch) and (is_binary(target_branch) or is_nil(target_branch)) do
    client_module().fetch_open_merge_request(source_branch, target_branch)
  end

  @spec create_merge_request_once(String.t(), String.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def create_merge_request_once(issue_id, run_fingerprint, source_branch, target_branch, title, description \\ nil)
      when is_binary(issue_id) and is_binary(run_fingerprint) and is_binary(source_branch) and
             is_binary(target_branch) and is_binary(title) and
             (is_binary(description) or is_nil(description)) do
    operation_key = writeback_key(issue_id, "merge-request", run_fingerprint)

    StateStore.writeback_once(
      operation_key,
      %{
        operation: "merge_request",
        issue_iid: issue_id,
        run_fingerprint: run_fingerprint,
        source_branch: source_branch,
        target_branch: target_branch,
        title: title
      },
      fn ->
        case fetch_open_merge_request(source_branch, target_branch) do
          {:ok, nil} ->
            client_module().create_merge_request(source_branch, target_branch, title, description)
            |> with_status_metadata("merge_request_status", "created")

          {:ok, merge_request} ->
            {:ok, Map.put(merge_request, "merge_request_status", "reused")}

          {:error, reason} ->
            {:error, reason}
        end
      end
    )
  end

  @spec record_existing_branch_once(String.t(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def record_existing_branch_once(issue_id, run_fingerprint, branch_name, ref, metadata \\ %{})
      when is_binary(issue_id) and is_binary(run_fingerprint) and is_binary(branch_name) and
             is_binary(ref) and is_map(metadata) do
    operation_key = writeback_key(issue_id, "branch", run_fingerprint)

    StateStore.writeback_once(
      operation_key,
      %{
        operation: "branch",
        issue_iid: issue_id,
        run_fingerprint: run_fingerprint,
        branch_name: branch_name,
        target_ref: ref
      },
      fn ->
        {:ok, Map.merge(%{"branch_status" => "recovered"}, metadata)}
      end
    )
  end

  @spec record_existing_commit_once(String.t(), String.t(), String.t(), String.t(), keyword(), map()) ::
          :ok | {:error, term()}
  def record_existing_commit_once(issue_id, run_fingerprint, branch_name, message, opts \\ [], metadata \\ %{})
      when is_binary(issue_id) and is_binary(run_fingerprint) and is_binary(branch_name) and
             is_binary(message) and is_list(opts) and is_map(metadata) do
    operation_key = writeback_key(issue_id, "commit", run_fingerprint)

    StateStore.writeback_once(
      operation_key,
      %{
        operation: "commit",
        issue_iid: issue_id,
        run_fingerprint: run_fingerprint,
        manifest_digest: Keyword.get(opts, :manifest_digest),
        action_digest: Keyword.get(opts, :action_digest),
        branch_name: branch_name,
        commit_message: message
      },
      fn ->
        {:ok, Map.merge(%{"commit_status" => "recovered"}, metadata)}
      end
    )
  end

  @spec record_existing_merge_request_once(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: :ok | {:error, term()}
  def record_existing_merge_request_once(
        issue_id,
        run_fingerprint,
        source_branch,
        target_branch,
        title,
        metadata
      )
      when is_binary(issue_id) and is_binary(run_fingerprint) and is_binary(source_branch) and
             is_binary(target_branch) and is_binary(title) and is_map(metadata) do
    operation_key = writeback_key(issue_id, "merge-request", run_fingerprint)

    StateStore.writeback_once(
      operation_key,
      %{
        operation: "merge_request",
        issue_iid: issue_id,
        run_fingerprint: run_fingerprint,
        source_branch: source_branch,
        target_branch: target_branch,
        title: title
      },
      fn ->
        {:ok, Map.merge(%{"merge_request_status" => "recovered"}, metadata)}
      end
    )
  end

  @spec fetch_merge_request_pipelines(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_merge_request_pipelines(merge_request_iid) when is_binary(merge_request_iid) do
    client_module().fetch_merge_request_pipelines(merge_request_iid)
  end

  defp lifecycle_labels_to_remove(state_name) do
    configured = Config.settings!().tracker.active_states ++ Config.settings!().tracker.terminal_states
    target = normalize_label(state_name)

    (@soc_lifecycle_labels ++ configured)
    |> Enum.reject(&(normalize_label(&1) == target))
    |> Enum.uniq_by(&normalize_label/1)
  end

  defp normalize_label(label) when is_binary(label), do: label |> String.trim() |> String.downcase()
  defp normalize_label(_label), do: ""

  defp writeback_key(issue_id, operation, key) do
    "issue:#{issue_id}:#{operation}:#{key}"
  end

  defp with_status_metadata({:ok, metadata}, key, value) when is_map(metadata) do
    {:ok, Map.put(metadata, key, value)}
  end

  defp with_status_metadata({:error, reason}, _key, _value), do: {:error, reason}

  defp client_module do
    Application.get_env(:symphony_elixir, :gitlab_client_module, Client)
  end
end
