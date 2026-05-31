defmodule SymphonyElixir.GitLab.MRWorkflow do
  @moduledoc """
  Stage 4 GitLab merge request workflow helpers.
  """

  alias SymphonyElixir.GitLab.Adapter

  @branch_prefix "soc/issue-"

  @spec branch_name(String.t(), String.t()) :: String.t()
  def branch_name(issue_iid, run_fingerprint)
      when is_binary(issue_iid) and is_binary(run_fingerprint) do
    sanitized_issue_iid =
      issue_iid
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    sanitized_fingerprint =
      run_fingerprint
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    "#{@branch_prefix}#{sanitized_issue_iid}/#{sanitized_fingerprint}"
  end

  @spec write_merge_request_link_comment(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def write_merge_request_link_comment(issue_iid, run_fingerprint, merge_request_url, source_branch)
      when is_binary(issue_iid) and is_binary(run_fingerprint) and is_binary(merge_request_url) and
             is_binary(source_branch) do
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
end
