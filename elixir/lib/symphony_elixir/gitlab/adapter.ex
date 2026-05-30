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

  @spec create_comment_once(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment_once(issue_id, comment_key, body)
      when is_binary(issue_id) and is_binary(comment_key) and is_binary(body) do
    operation_key = writeback_key(issue_id, "comment", comment_key)

    StateStore.writeback_once(
      operation_key,
      %{
        operation: "comment",
        issue_iid: issue_id,
        comment_key: comment_key
      },
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

  defp client_module do
    Application.get_env(:symphony_elixir, :gitlab_client_module, Client)
  end
end
