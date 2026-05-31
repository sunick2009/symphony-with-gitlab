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

  defp configure_lifecycle_test(agent_runner_module) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "token",
      tracker_project_slug: "group/project",
      tracker_webhook_secret: "secret",
      tracker_state_path: Path.join(System.tmp_dir!(), "symphony-gitlab-lifecycle-state-#{System.unique_integer([:positive])}.json"),
      tracker_active_states: ["soc::queued"],
      tracker_terminal_states: ["soc::done", "soc::failed"],
      poll_interval_ms: 10
    )

    Application.put_env(:symphony_elixir, :gitlab_client_module, FakeGitLabClient)
    Application.put_env(:symphony_elixir, :agent_runner_module, agent_runner_module)
    Application.put_env(:symphony_elixir, :gitlab_test_recipient, self())
    Application.put_env(:symphony_elixir, :gitlab_lifecycle_issue_state, "soc::queued")
    StateStore.reset_for_test()
  end
end
