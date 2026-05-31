defmodule SymphonyElixir.GitLabLifecycleTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.GitLab.StateStore

  defmodule FakeGitLabClient do
    @spec fetch_candidate_issues() :: {:ok, [Issue.t()]}
    def fetch_candidate_issues do
      issue = current_issue()
      active_states = Config.settings!().tracker.active_states |> Enum.map(&String.downcase/1)

      if String.downcase(issue.state) in active_states do
        {:ok, [issue]}
      else
        {:ok, []}
      end
    end

    @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issues_by_states(_states), do: {:ok, []}

    @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issue_states_by_ids(issue_ids) do
      issue = current_issue()

      if issue.id in issue_ids do
        {:ok, [issue]}
      else
        {:ok, []}
      end
    end

    @spec post_issue_comment(String.t(), String.t()) :: :ok
    def post_issue_comment(issue_iid, body) do
      send(test_recipient(), {:gitlab_comment, issue_iid, body})
      :ok
    end

    @spec update_issue_labels(String.t(), [String.t()], [String.t()]) :: :ok
    def update_issue_labels(issue_iid, add_labels, remove_labels) do
      [state | _] = add_labels
      Application.put_env(:symphony_elixir, :gitlab_lifecycle_issue_state, state)
      send(test_recipient(), {:gitlab_labels, issue_iid, add_labels, remove_labels})
      :ok
    end

    @spec fetch_branch(String.t()) :: {:ok, map() | nil}
    def fetch_branch(branch_name) when is_binary(branch_name) do
      send(test_recipient(), {:gitlab_live_branch_fetch, branch_name})
      {:ok, nil}
    end

    @spec create_branch(String.t(), String.t()) :: {:ok, map()}
    def create_branch(branch_name, ref) when is_binary(branch_name) and is_binary(ref) do
      send(test_recipient(), {:gitlab_live_branch_create, branch_name, ref})
      {:ok, %{"branch_name" => branch_name}}
    end

    @spec create_commit(String.t(), String.t(), [map()], keyword()) :: {:ok, map()}
    def create_commit(branch_name, message, actions, _opts)
        when is_binary(branch_name) and is_binary(message) and is_list(actions) do
      send(test_recipient(), {:gitlab_live_commit_create, branch_name, message, actions})
      {:ok, %{"commit_sha" => "dry-run-should-not-happen"}}
    end

    @spec fetch_open_merge_request(String.t(), String.t() | nil) :: {:ok, map() | nil}
    def fetch_open_merge_request(source_branch, target_branch)
        when is_binary(source_branch) and (is_binary(target_branch) or is_nil(target_branch)) do
      send(test_recipient(), {:gitlab_live_mr_fetch, source_branch, target_branch})
      {:ok, nil}
    end

    @spec create_merge_request(String.t(), String.t(), String.t(), String.t() | nil) :: {:ok, map()}
    def create_merge_request(source_branch, target_branch, title, description)
        when is_binary(source_branch) and is_binary(target_branch) and is_binary(title) do
      send(test_recipient(), {:gitlab_live_mr_create, source_branch, target_branch, title, description})

      {:ok,
       %{
         "merge_request_iid" => "dry-run-should-not-happen",
         "merge_request_url" => "https://gitlab.example.com/group/project/-/merge_requests/dry-run-should-not-happen"
       }}
    end

    @spec fetch_merge_request_pipelines(String.t()) :: {:ok, [map()]}
    def fetch_merge_request_pipelines(merge_request_iid) when is_binary(merge_request_iid) do
      send(test_recipient(), {:gitlab_live_pipeline_fetch, merge_request_iid})
      {:ok, []}
    end

    defp current_issue do
      state = Application.get_env(:symphony_elixir, :gitlab_lifecycle_issue_state, "soc::queued")

      %Issue{
        id: "42",
        identifier: "#42",
        title: "Investigate alert",
        description: "Body",
        state: state,
        labels: [state],
        url: "https://gitlab.example.com/group/project/-/issues/42"
      }
    end

    defp test_recipient do
      Application.fetch_env!(:symphony_elixir, :gitlab_test_recipient)
    end
  end

  defmodule SuccessfulRunner do
    @spec run(map(), pid() | nil, keyword()) :: :ok
    def run(issue, recipient, _opts) do
      send(test_recipient(), {:agent_run, issue.id, recipient})
      Process.sleep(25)
      :ok
    end

    defp test_recipient do
      Application.fetch_env!(:symphony_elixir, :gitlab_test_recipient)
    end
  end

  defmodule DryRunSuccessfulRunner do
    @spec run(map(), pid() | nil, keyword()) :: :ok
    def run(issue, recipient, _opts) when is_pid(recipient) do
      workspace_root = Config.settings!().workspace.root
      workspace = Path.join(workspace_root, "_42")
      manifest_path = Path.join(workspace, ".symphony/gitlab_artifacts.json")
      output_path = Path.join(workspace, "out/generated_from_hook.ex")

      File.mkdir_p!(Path.dirname(manifest_path))
      File.mkdir_p!(Path.dirname(output_path))

      File.write!(
        manifest_path,
        Jason.encode!(%{
          "version" => 1,
          "artifacts" => [
            %{
              "repository_path" => "elixir/lib/generated_from_hook.ex",
              "workspace_source_path" => "out/generated_from_hook.ex",
              "action" => "create",
              "content_type" => "text/plain"
            }
          ]
        })
      )

      File.write!(
        output_path,
        """
        defmodule GeneratedFromHook do
        end
        """
      )

      send(recipient, {:worker_runtime_info, issue.id, %{workspace_path: workspace, worker_host: nil}})
      send(test_recipient(), {:agent_run, issue.id, recipient})
      Process.sleep(25)
      :ok
    end

    defp test_recipient do
      Application.fetch_env!(:symphony_elixir, :gitlab_test_recipient)
    end
  end

  defmodule FailingRunner do
    @spec run(map(), pid() | nil, keyword()) :: no_return()
    def run(issue, _recipient, _opts) do
      send(test_recipient(), {:agent_run, issue.id, :failing})
      raise "simulated agent failure"
    end

    defp test_recipient do
      Application.fetch_env!(:symphony_elixir, :gitlab_test_recipient)
    end
  end

  test "queued gitlab issue dispatches to running and completes to human review with adapter comment" do
    configure_lifecycle_test(SuccessfulRunner)

    {:ok, pid} = Orchestrator.start_link(name: :"gitlab-lifecycle-success-#{System.unique_integer([:positive])}")

    try do
      assert_receive {:gitlab_labels, "42", ["soc::running"], _removed}, 1_000
      assert_receive {:agent_run, "42", recipient} when is_pid(recipient)
      assert_receive {:gitlab_labels, "42", ["soc::human-review"], _removed}, 1_000

      assert_receive {:gitlab_comment, "42", "Symphony agent run completed and moved this issue to `soc::human-review`."},
                     1_000
    after
      GenServer.stop(pid)
    end
  end

  test "failing gitlab issue dispatch moves to failed with adapter comment" do
    configure_lifecycle_test(FailingRunner)

    {:ok, pid} = Orchestrator.start_link(name: :"gitlab-lifecycle-failure-#{System.unique_integer([:positive])}")

    try do
      assert_receive {:gitlab_labels, "42", ["soc::running"], _removed}, 1_000
      assert_receive {:agent_run, "42", :failing}, 1_000
      assert_receive {:gitlab_labels, "42", ["soc::failed"], _removed}, 1_000

      assert_receive {:gitlab_comment, "42", "Symphony agent run failed and moved this issue to `soc::failed`."},
                     1_000
    after
      GenServer.stop(pid)
    end
  end

  test "successful gitlab issue completion records a dry-run mr finalization plan without live mutation" do
    configure_lifecycle_test(DryRunSuccessfulRunner)

    {:ok, pid} = Orchestrator.start_link(name: :"gitlab-lifecycle-dryrun-#{System.unique_integer([:positive])}")

    try do
      assert_receive {:gitlab_labels, "42", ["soc::running"], _removed}, 1_000
      assert_receive {:agent_run, "42", recipient} when is_pid(recipient)
      assert_receive {:gitlab_labels, "42", ["soc::human-review"], _removed}, 1_000

      state = StateStore.read_for_test()
      stage4 = state["issue_runs"]["42"]["stage4"]
      assert stage4["stage4_status"] == "dry-run-planned"
      assert is_binary(stage4["manifest_digest"])
      assert is_binary(stage4["action_digest"])
      assert stage4["branch_name"] =~ "soc/issue-42/"

      refute_receive {:gitlab_live_branch_fetch, _branch_name}
      refute_receive {:gitlab_live_branch_create, _, _}
      refute_receive {:gitlab_live_commit_create, _, _, _}
      refute_receive {:gitlab_live_mr_fetch, _, _}
      refute_receive {:gitlab_live_mr_create, _, _, _, _}
    after
      GenServer.stop(pid)
    end
  end

  test "successful gitlab issue completion creates a live staging branch commit and merge request when enabled" do
    configure_lifecycle_test(DryRunSuccessfulRunner,
      tracker_stage4_live_mutation: true,
      tracker_stage4_allowed_project_slugs: ["group/project"]
    )

    {:ok, pid} = Orchestrator.start_link(name: :"gitlab-lifecycle-live-#{System.unique_integer([:positive])}")

    try do
      assert_receive {:gitlab_labels, "42", ["soc::running"], _removed}, 1_000
      assert_receive {:agent_run, "42", recipient} when is_pid(recipient)
      assert_receive {:gitlab_live_branch_fetch, branch_name}, 1_000
      assert branch_name =~ "soc/issue-42/"
      assert_receive {:gitlab_live_branch_create, ^branch_name, "main"}, 1_000
      assert_receive {:gitlab_live_commit_create, ^branch_name, _message, _actions}, 1_000
      assert_receive {:gitlab_live_mr_fetch, ^branch_name, "main"}, 1_000
      assert_receive {:gitlab_live_mr_create, ^branch_name, "main", _title, _description}, 1_000
      assert_receive {:gitlab_labels, "42", ["soc::human-review"], _removed}, 1_000
      assert_receive {:gitlab_comment, "42", first_body}, 1_000
      assert_receive {:gitlab_comment, "42", second_body}, 1_000

      assert Enum.any?([first_body, second_body], &String.contains?(&1, "merge request"))
      assert Enum.any?([first_body, second_body], &String.contains?(&1, "soc::human-review"))

      stage4 = StateStore.read_for_test()["issue_runs"]["42"]["stage4"]
      assert stage4["stage4_status"] == "live-mr-created"
      assert stage4["merge_request_url"] =~ "/merge_requests/"
      assert stage4["commit_sha"] == "dry-run-should-not-happen"
    after
      GenServer.stop(pid)
    end
  end

  test "staging-live guard prevents accidental production targeting during completion" do
    configure_lifecycle_test(DryRunSuccessfulRunner,
      tracker_stage4_live_mutation: true,
      tracker_stage4_allowed_project_slugs: ["group/disposable-only"]
    )

    {:ok, pid} = Orchestrator.start_link(name: :"gitlab-lifecycle-guard-#{System.unique_integer([:positive])}")

    try do
      assert_receive {:gitlab_labels, "42", ["soc::running"], _removed}, 1_000
      assert_receive {:agent_run, "42", recipient} when is_pid(recipient)
      refute_receive {:gitlab_live_branch_fetch, _branch_name}, 300
      refute_receive {:gitlab_live_branch_create, _, _}, 300
      refute_receive {:gitlab_live_commit_create, _, _, _}, 300
      refute_receive {:gitlab_live_mr_create, _, _, _, _}, 300
      assert_receive {:gitlab_labels, "42", ["soc::human-review"], _removed}, 1_000

      stage4 = StateStore.read_for_test()["issue_runs"]["42"]["stage4"]
      assert stage4["stage4_status"] == "finalization-error"
      assert stage4["stage4_error"] =~ "stage4_live_project_not_allowlisted"
    after
      GenServer.stop(pid)
    end
  end

  defp configure_lifecycle_test(agent_runner_module, opts \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "gitlab",
          tracker_endpoint: "https://gitlab.example.com",
          tracker_api_token: "token",
          tracker_project_slug: "group/project",
          tracker_webhook_secret: "secret",
          tracker_state_path: Path.join(System.tmp_dir!(), "symphony-gitlab-lifecycle-state-#{System.unique_integer([:positive])}.json"),
          tracker_active_states: ["soc::queued"],
          tracker_terminal_states: ["soc::done", "soc::failed"],
          poll_interval_ms: 10,
          hook_after_run: Keyword.get(opts, :hook_after_run)
        ],
        Keyword.drop(opts, [:hook_after_run])
      )
    )

    Application.put_env(:symphony_elixir, :gitlab_client_module, FakeGitLabClient)
    Application.put_env(:symphony_elixir, :agent_runner_module, agent_runner_module)
    Application.put_env(:symphony_elixir, :gitlab_test_recipient, self())
    Application.put_env(:symphony_elixir, :gitlab_lifecycle_issue_state, "soc::queued")
    StateStore.reset_for_test()
  end
end
