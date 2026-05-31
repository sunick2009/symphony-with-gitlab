defmodule SymphonyElixir.GitLabMRWorkflowTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitLab.{Adapter, Client, MRWorkflow, StateStore}

  defmodule FakeGitLabMRClient do
    @spec fetch_branch(String.t()) :: {:ok, map() | nil}
    def fetch_branch(branch_name) when is_binary(branch_name) do
      {:ok, get_in(remote_state(), [:branches, branch_name])}
    end

    @spec create_branch(String.t(), String.t()) :: {:ok, map()}
    def create_branch(branch_name, ref) when is_binary(branch_name) and is_binary(ref) do
      branch = %{
        "branch_name" => branch_name,
        "name" => branch_name,
        "commit_id" => ref
      }

      put_in_remote_state([:branches, branch_name], branch)
      send(test_recipient(), {:gitlab_branch_created, branch_name, ref})
      {:ok, branch}
    end

    @spec create_commit(String.t(), String.t(), [map()], keyword()) :: {:ok, map()}
    def create_commit(branch_name, message, actions, _opts)
        when is_binary(branch_name) and is_binary(message) and is_list(actions) do
      commit_sha = "sha-#{System.unique_integer([:positive])}"

      commit = %{
        "commit_sha" => commit_sha,
        "message" => message,
        "branch_name" => branch_name,
        "action_count" => length(actions)
      }

      put_in_remote_state([:commits, branch_name], commit)
      send(test_recipient(), {:gitlab_commit_created, branch_name, message, actions})
      {:ok, commit}
    end

    @spec fetch_open_merge_request(String.t(), String.t() | nil) :: {:ok, map() | nil}
    def fetch_open_merge_request(source_branch, target_branch)
        when is_binary(source_branch) and (is_binary(target_branch) or is_nil(target_branch)) do
      merge_request =
        remote_state()
        |> Map.get(:merge_requests, %{})
        |> Map.values()
        |> Enum.find(fn merge_request ->
          merge_request["source_branch"] == source_branch and
            (is_nil(target_branch) or merge_request["target_branch"] == target_branch) and
            merge_request["state"] == "opened"
        end)

      {:ok, merge_request}
    end

    @spec create_merge_request(String.t(), String.t(), String.t(), String.t() | nil) :: {:ok, map()}
    def create_merge_request(source_branch, target_branch, title, description)
        when is_binary(source_branch) and is_binary(target_branch) and is_binary(title) do
      merge_request_iid = Integer.to_string(System.unique_integer([:positive]))

      merge_request = %{
        "merge_request_iid" => merge_request_iid,
        "merge_request_url" => "https://gitlab.example.com/group/project/-/merge_requests/#{merge_request_iid}",
        "source_branch" => source_branch,
        "target_branch" => target_branch,
        "title" => title,
        "description" => description,
        "state" => "opened"
      }

      put_in_remote_state([:merge_requests, merge_request_iid], merge_request)
      send(test_recipient(), {:gitlab_merge_request_created, source_branch, target_branch, title})
      {:ok, merge_request}
    end

    @spec post_issue_comment(String.t(), String.t()) :: :ok
    def post_issue_comment(issue_iid, body) when is_binary(issue_iid) and is_binary(body) do
      send(test_recipient(), {:gitlab_comment, issue_iid, body})
      :ok
    end

    @spec fetch_merge_request_pipelines(String.t()) :: {:ok, [map()]}
    def fetch_merge_request_pipelines(merge_request_iid) when is_binary(merge_request_iid) do
      pipelines =
        remote_state()
        |> Map.get(:pipelines, %{})
        |> Map.get(merge_request_iid, [])

      {:ok, pipelines}
    end

    defp remote_state do
      pid = Application.fetch_env!(:symphony_elixir, :gitlab_mr_remote_state)
      Agent.get(pid, & &1)
    end

    defp put_in_remote_state(path, value) do
      pid = Application.fetch_env!(:symphony_elixir, :gitlab_mr_remote_state)
      Agent.update(pid, &Kernel.put_in(&1, path, value))
    end

    defp test_recipient do
      Application.fetch_env!(:symphony_elixir, :gitlab_test_recipient)
    end
  end

  test "branch name generation is deterministic and sanitized" do
    assert MRWorkflow.branch_name("Issue 42", "AB_cd.123") == "soc/issue-issue-42/ab-cd-123"
  end

  test "gitlab client creates branches through the branches API" do
    configure_request_test()

    request_fun = fn :post, url, opts ->
      send(self(), {:gitlab_request, :post, url, opts})

      {:ok,
       %{
         status: 201,
         body: %{
           "name" => "soc/issue-42/run-123",
           "commit" => %{"id" => "abc123"}
         }
       }}
    end

    assert {:ok, branch} =
             Client.create_branch_for_test(
               "soc/issue-42/run-123",
               "main",
               request_fun
             )

    assert branch["branch_name"] == "soc/issue-42/run-123"
    assert branch["commit_id"] == "abc123"

    assert_receive {:gitlab_request, :post, url, opts}
    assert url == "https://gitlab.example.com/api/v4/projects/group%2Fproject/repository/branches"
    assert opts[:json] == %{"branch" => "soc/issue-42/run-123", "ref" => "main"}
  end

  test "gitlab client creates commits through the commits API" do
    configure_request_test()

    request_fun = fn :post, url, opts ->
      send(self(), {:gitlab_request, :post, url, opts})

      {:ok,
       %{
         status: 201,
         body: %{
           "id" => "deadbeef",
           "short_id" => "deadbee",
           "title" => "feat: update file"
         }
       }}
    end

    actions = [%{action: "update", file_path: "README.md", content: "hello"}]

    assert {:ok, commit} =
             Client.create_commit_for_test(
               "soc/issue-42/run-123",
               "feat: update file",
               actions,
               [start_branch: "main"],
               request_fun
             )

    assert commit["commit_sha"] == "deadbeef"

    assert_receive {:gitlab_request, :post, url, opts}
    assert url == "https://gitlab.example.com/api/v4/projects/group%2Fproject/repository/commits"

    assert opts[:json] == %{
             "actions" => [%{"action" => "update", "content" => "hello", "file_path" => "README.md"}],
             "branch" => "soc/issue-42/run-123",
             "commit_message" => "feat: update file",
             "start_branch" => "main"
           }
  end

  test "gitlab client fetches and creates merge requests through the merge requests API" do
    configure_request_test()

    request_fun = fn
      :get, url, opts ->
        send(self(), {:gitlab_request, :get, url, opts})

        {:ok,
         %{
           status: 200,
           body: [
             %{
               "iid" => 9,
               "web_url" => "https://gitlab.example.com/group/project/-/merge_requests/9",
               "source_branch" => "soc/issue-42/run-123",
               "target_branch" => "main",
               "state" => "opened",
               "title" => "MR title"
             }
           ]
         }}

      :post, url, opts ->
        send(self(), {:gitlab_request, :post, url, opts})

        {:ok,
         %{
           status: 201,
           body: %{
             "iid" => 10,
             "web_url" => "https://gitlab.example.com/group/project/-/merge_requests/10",
             "source_branch" => "soc/issue-42/run-123",
             "target_branch" => "main",
             "state" => "opened",
             "title" => "MR title"
           }
         }}
    end

    assert {:ok, merge_request} =
             Client.fetch_open_merge_request_for_test(
               "soc/issue-42/run-123",
               "main",
               request_fun
             )

    assert merge_request["merge_request_iid"] == "9"

    assert {:ok, created_merge_request} =
             Client.create_merge_request_for_test(
               "soc/issue-42/run-123",
               "main",
               "MR title",
               "MR description",
               request_fun
             )

    assert created_merge_request["merge_request_iid"] == "10"

    assert_receive {:gitlab_request, :get, get_url, get_opts}
    assert get_url == "https://gitlab.example.com/api/v4/projects/group%2Fproject/merge_requests"
    assert get_opts[:params]["source_branch"] == "soc/issue-42/run-123"
    assert get_opts[:params]["target_branch"] == "main"
    assert get_opts[:params]["state"] == "opened"

    assert_receive {:gitlab_request, :post, post_url, post_opts}
    assert post_url == "https://gitlab.example.com/api/v4/projects/group%2Fproject/merge_requests"

    assert post_opts[:json] == %{
             "description" => "MR description",
             "source_branch" => "soc/issue-42/run-123",
             "target_branch" => "main",
             "title" => "MR title"
           }
  end

  test "adapter suppresses duplicate branch creation when the branch already exists remotely" do
    configure_mr_workflow_test()

    branch_name = MRWorkflow.branch_name("42", "run-123")
    remote_put([:branches, branch_name], %{"branch_name" => branch_name, "commit_id" => "main"})

    assert :ok = Adapter.create_branch_once("42", "run-123", branch_name, "main")
    refute_receive {:gitlab_branch_created, ^branch_name, "main"}

    state = StateStore.read_for_test()
    assert state["writebacks"]["issue:42:branch:run-123"]["status"] == "done"
    assert state["writebacks"]["issue:42:branch:run-123"]["result_metadata"]["branch_status"] == "reused"
    assert state["issue_runs"]["42"]["stage4"]["branch_name"] == branch_name
  end

  test "adapter commit creation is idempotent within the state store" do
    configure_mr_workflow_test()

    actions = [%{action: "update", file_path: "README.md", content: "hello"}]

    assert :ok =
             Adapter.create_commit_once(
               "42",
               "run-commit",
               "soc/issue-42/run-commit",
               "feat: update file",
               actions,
               []
             )

    assert_receive {:gitlab_commit_created, "soc/issue-42/run-commit", "feat: update file", ^actions}

    assert :ok =
             Adapter.create_commit_once(
               "42",
               "run-commit",
               "soc/issue-42/run-commit",
               "feat: update file",
               actions,
               []
             )

    refute_receive {:gitlab_commit_created, "soc/issue-42/run-commit", "feat: update file", ^actions}

    state = StateStore.read_for_test()
    assert state["writebacks"]["issue:42:commit:run-commit"]["status"] == "done"
    assert state["issue_runs"]["42"]["stage4"]["commit_sha"] =~ "sha-"
  end

  test "adapter suppresses duplicate merge request creation when an open merge request already exists remotely" do
    configure_mr_workflow_test()

    source_branch = MRWorkflow.branch_name("42", "run-mr")

    remote_put(
      [:merge_requests, "11"],
      %{
        "merge_request_iid" => "11",
        "merge_request_url" => "https://gitlab.example.com/group/project/-/merge_requests/11",
        "source_branch" => source_branch,
        "target_branch" => "main",
        "title" => "Issue #42",
        "state" => "opened"
      }
    )

    assert :ok =
             Adapter.create_merge_request_once(
               "42",
               "run-mr",
               source_branch,
               "main",
               "Issue #42",
               "MR body"
             )

    refute_receive {:gitlab_merge_request_created, ^source_branch, "main", "Issue #42"}

    state = StateStore.read_for_test()
    assert state["writebacks"]["issue:42:merge-request:run-mr"]["result_metadata"]["merge_request_status"] == "reused"
    assert state["issue_runs"]["42"]["stage4"]["merge_request_iid"] == "11"
  end

  test "mr link and ci failure writeback remain adapter-owned and idempotent" do
    configure_mr_workflow_test()

    assert :ok =
             MRWorkflow.write_merge_request_link_comment(
               "42",
               "run-link",
               "https://gitlab.example.com/group/project/-/merge_requests/12",
               "soc/issue-42/run-link"
             )

    assert_receive {:gitlab_comment, "42", body}
    assert body =~ "merge request"
    assert body =~ "soc/issue-42/run-link"

    assert :ok =
             MRWorkflow.write_merge_request_link_comment(
               "42",
               "run-link",
               "https://gitlab.example.com/group/project/-/merge_requests/12",
               "soc/issue-42/run-link"
             )

    refute_receive {:gitlab_comment, "42", _body}

    assert :ok =
             MRWorkflow.write_ci_failure_comment(
               "42",
               "12",
               "https://gitlab.example.com/group/project/-/merge_requests/12",
               "failed"
             )

    assert_receive {:gitlab_comment, "42", failure_body}
    assert failure_body =~ "CI status `failed`"

    state = StateStore.read_for_test()

    assert state["issue_runs"]["42"]["stage4"]["merge_request_url"] ==
             "https://gitlab.example.com/group/project/-/merge_requests/12"

    assert state["issue_runs"]["42"]["stage4"]["pipeline_status"] == "failed"
  end

  test "gitlab token stays out of codex runtime settings during mr workflow foundations" do
    previous_gitlab_api_token = System.get_env("GITLAB_API_TOKEN")
    on_exit(fn -> restore_env("GITLAB_API_TOKEN", previous_gitlab_api_token) end)
    System.put_env("GITLAB_API_TOKEN", "glpat-stage4-secret")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: nil,
      tracker_project_slug: "group/project",
      prompt: "Work on {{ issue.identifier }} without credentials."
    )

    issue = %Issue{id: "42", identifier: "#42", title: "Stage 4", state: "soc::queued"}

    assert {:ok, runtime_settings} = Config.codex_runtime_settings("/tmp/workspace")
    refute inspect(runtime_settings) =~ "glpat-stage4-secret"
    refute PromptBuilder.build_prompt(issue) =~ "glpat-stage4-secret"
  end

  defp configure_request_test do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "token",
      tracker_project_slug: "group/project"
    )
  end

  defp configure_mr_workflow_test do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "token",
      tracker_project_slug: "group/project",
      tracker_webhook_secret: "secret",
      tracker_state_path: unique_gitlab_state_path(),
      tracker_active_states: ["soc::queued"],
      tracker_terminal_states: ["soc::done", "soc::failed"]
    )

    {:ok, remote_state} =
      Agent.start_link(fn ->
        %{
          branches: %{},
          commits: %{},
          merge_requests: %{},
          pipelines: %{}
        }
      end)

    Application.put_env(:symphony_elixir, :gitlab_client_module, FakeGitLabMRClient)
    Application.put_env(:symphony_elixir, :gitlab_mr_remote_state, remote_state)
    Application.put_env(:symphony_elixir, :gitlab_test_recipient, self())
    StateStore.reset_for_test()

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :gitlab_mr_remote_state)
    end)
  end

  defp unique_gitlab_state_path do
    Path.join(System.tmp_dir!(), "symphony-gitlab-mr-state-#{System.unique_integer([:positive])}.json")
  end

  defp remote_put(path, value) do
    pid = Application.fetch_env!(:symphony_elixir, :gitlab_mr_remote_state)
    Agent.update(pid, &Kernel.put_in(&1, path, value))
  end
end
