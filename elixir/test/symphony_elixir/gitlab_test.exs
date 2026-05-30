defmodule SymphonyElixir.GitLabTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitLab.{Adapter, Client, Command, Webhook}

  defmodule FakeGitLabClient do
    @spec fetch_candidate_issues() :: {:ok, [term()]}
    def fetch_candidate_issues, do: {:ok, []}

    @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]}
    def fetch_issues_by_states(_states), do: {:ok, []}

    @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]}
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}

    @spec post_issue_comment(String.t(), String.t()) :: :ok
    def post_issue_comment(issue_iid, body) do
      send(test_recipient(), {:gitlab_comment, issue_iid, body})
      :ok
    end

    @spec update_issue_labels(String.t(), [String.t()], [String.t()]) :: :ok
    def update_issue_labels(issue_iid, add_labels, remove_labels) do
      send(test_recipient(), {:gitlab_labels, issue_iid, add_labels, remove_labels})
      :ok
    end

    defp test_recipient do
      Application.fetch_env!(:symphony_elixir, :gitlab_test_recipient)
    end
  end

  test "gitlab tracker config is accepted and resolves token from GITLAB_API_TOKEN" do
    previous_gitlab_api_token = System.get_env("GITLAB_API_TOKEN")
    on_exit(fn -> restore_env("GITLAB_API_TOKEN", previous_gitlab_api_token) end)
    System.put_env("GITLAB_API_TOKEN", "gitlab-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: nil,
      tracker_api_token: nil,
      tracker_project_slug: "group/project"
    )

    assert :ok = Config.validate!()
    assert Config.settings!().tracker.endpoint == "https://gitlab.com"
    assert Config.settings!().tracker.api_key == "gitlab-token"
    assert Tracker.adapter() == Adapter
  end

  test "gitlab issue normalization derives label-based state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "token",
      tracker_project_slug: "group/project",
      tracker_active_states: ["soc::queued"],
      tracker_terminal_states: ["soc::done"]
    )

    issue =
      Client.normalize_issue_for_test(%{
        "iid" => 42,
        "title" => "Investigate alert",
        "description" => "Body",
        "state" => "opened",
        "labels" => ["SOC::Queued"],
        "references" => %{"relative" => "#42"},
        "web_url" => "https://gitlab.example.com/group/project/-/issues/42"
      })

    assert issue.id == "42"
    assert issue.identifier == "#42"
    assert issue.state == "soc::queued"
    assert issue.labels == ["soc::queued"]
  end

  test "gitlab issue normalization gives terminal labels priority over active labels" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "token",
      tracker_project_slug: "group/project",
      tracker_active_states: ["soc::queued"],
      tracker_terminal_states: ["soc::failed", "soc::done"]
    )

    issue =
      Client.normalize_issue_for_test(%{
        "iid" => 42,
        "title" => "Investigate alert",
        "state" => "opened",
        "labels" => ["soc::queued", "SOC::Failed"]
      })

    assert issue.state == "soc::failed"
  end

  test "gitlab label update sends add and remove labels through the adapter layer" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "token",
      tracker_project_slug: "group/project"
    )

    request_fun = fn method, url, opts ->
      send(self(), {:gitlab_request, method, url, opts})
      {:ok, %{status: 200, body: %{}}}
    end

    assert :ok =
             Client.update_issue_labels_for_test(
               "42",
               ["soc::queued"],
               ["soc::running", ""],
               request_fun
             )

    assert_receive {:gitlab_request, :put, url, opts}
    assert url == "https://gitlab.example.com/api/v4/projects/group%2Fproject/issues/42"
    assert opts[:json] == %{"add_labels" => "soc::queued", "remove_labels" => "soc::running"}
  end

  test "gitlab adapter transition removes conflicting lifecycle labels without removing target" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "token",
      tracker_project_slug: "group/project",
      tracker_active_states: ["soc::queued"],
      tracker_terminal_states: ["soc::done"]
    )

    Application.put_env(:symphony_elixir, :gitlab_client_module, FakeGitLabClient)
    Application.put_env(:symphony_elixir, :gitlab_test_recipient, self())

    assert :ok = Adapter.update_issue_state("42", "soc::running")
    assert_receive {:gitlab_labels, "42", ["soc::running"], removed_labels}
    refute "soc::running" in removed_labels
    assert "soc::queued" in removed_labels
    assert "soc::human-review" in removed_labels
    assert "soc::done" in removed_labels
  end

  test "gitlab client surfaces writeback status errors" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "token",
      tracker_project_slug: "group/project"
    )

    request_fun = fn _method, _url, _opts ->
      {:ok, %{status: 403, body: %{"message" => "forbidden"}}}
    end

    assert {:error, {:gitlab_api_status, 403}} =
             Client.update_issue_labels_for_test(
               "42",
               ["soc::queued"],
               [],
               request_fun
             )
  end

  test "gitlab polling fetches configured active labels and deduplicates issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "token",
      tracker_project_slug: "group/project",
      tracker_active_states: ["soc::queued", "soc::rework"],
      tracker_terminal_states: ["soc::done"]
    )

    request_fun = fn :get, _url, opts ->
      send(self(), {:gitlab_poll_params, opts[:params]})

      {:ok,
       %Req.Response{
         status: 200,
         headers: %{"x-next-page" => []},
         body: [
           %{
             "iid" => 42,
             "title" => "Investigate alert",
             "state" => "opened",
             "labels" => [opts[:params]["labels"]],
             "references" => %{"relative" => "#42"}
           }
         ]
       }}
    end

    previous = Application.get_env(:symphony_elixir, :gitlab_request_fun)
    Application.put_env(:symphony_elixir, :gitlab_request_fun, request_fun)

    try do
      assert {:ok, [issue]} = Client.fetch_candidate_issues()
      assert issue.id == "42"
      assert_receive {:gitlab_poll_params, %{:state => "opened", "labels" => "soc::queued"}}
      assert_receive {:gitlab_poll_params, %{:state => "opened", "labels" => "soc::rework"}}
    after
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :gitlab_request_fun)
        value -> Application.put_env(:symphony_elixir, :gitlab_request_fun, value)
      end
    end
  end

  test "gitlab token stays out of codex runtime settings and rendered prompt" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "glpat-secret-token",
      tracker_project_slug: "group/project",
      prompt: "Handle {{ issue.identifier }} without credentials."
    )

    issue = %Issue{
      id: "42",
      identifier: "#42",
      title: "Investigate alert",
      description: "Body",
      state: "soc::queued",
      labels: ["soc::queued"]
    }

    assert {:ok, runtime_settings} = Config.codex_runtime_settings("/tmp/workspace")
    refute inspect(runtime_settings) =~ "glpat-secret-token"
    refute PromptBuilder.build_prompt(issue) =~ "glpat-secret-token"
  end

  test "command parser only accepts commands at the beginning of a line" do
    assert :ignore = Command.parse("Please run /soc run later")
    assert :ignore = Command.parse("/soccer run")
    assert {:ok, [%Command{name: "run"}]} = Command.parse("/soc run\nnormal text")
    assert {:ok, [%Command{name: "status"}]} = Command.parse("intro\n/soc status")
    assert {:error, {:unknown_command, "dance"}} = Command.parse("/soc dance")
  end

  test "webhook rejects missing and invalid secrets before writeback" do
    configure_gitlab_webhook_test()

    base_headers = %{
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-secret"
    }

    assert {:error, :missing_gitlab_webhook_token} = Webhook.handle(base_headers, note_payload("/soc run"))
    assert {:error, :invalid_gitlab_webhook_token} = Webhook.handle(Map.put(base_headers, "x-gitlab-token", "wrong"), note_payload("/soc run"))
    refute_receive {:gitlab_labels, "42", _add, _remove}
    refute_receive {:gitlab_comment, "42", _body}
  end

  test "webhook handles soc run with secret validation, idempotency, comment writeback, and label transition" do
    configure_gitlab_webhook_test()

    headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-1"
    }

    assert {:ok, :handled} = Webhook.handle(headers, note_payload("/soc run"))

    assert_receive {:gitlab_labels, "42", ["soc::queued"], removed_labels}
    assert "soc::running" in removed_labels
    assert_receive {:gitlab_comment, "42", "Symphony accepted `/soc run` and queued this issue for an agent run."}

    assert {:ok, :duplicate} = Webhook.handle(headers, note_payload("/soc run"))
    refute_receive {:gitlab_labels, "42", _add, _remove}
    refute_receive {:gitlab_comment, "42", _body}
  end

  test "webhook rejects duplicate run commands for claimed or running issues" do
    configure_gitlab_webhook_test()

    headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-running"
    }

    assert {:error, :issue_already_running} =
             Webhook.handle(headers, note_payload("/soc run", labels: ["soc::running"]))

    assert_receive {:gitlab_comment, "42", "Symphony cannot queue this issue because it is already claimed or running."}
    refute_receive {:gitlab_labels, "42", _add, _remove}
  end

  test "webhook parses recognized but unimplemented commands without dispatching" do
    configure_gitlab_webhook_test()

    headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-2"
    }

    assert {:ok, :handled} = Webhook.handle(headers, note_payload("/soc status"))
    assert_receive {:gitlab_comment, "42", "The `/soc status` command is recognized but is not implemented yet."}
    refute_receive {:gitlab_labels, "42", _add, _remove}
  end

  test "webhook rejects closed issues with an adapter-owned comment" do
    configure_gitlab_webhook_test()

    headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-3"
    }

    assert {:error, :closed_issue} = Webhook.handle(headers, note_payload("/soc run", issue_state: "closed"))
    assert_receive {:gitlab_comment, "42", "Symphony cannot run on a closed GitLab issue."}
    refute_receive {:gitlab_labels, "42", _add, _remove}
  end

  defp configure_gitlab_webhook_test do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "token",
      tracker_project_slug: "group/project",
      tracker_webhook_secret: "secret",
      tracker_active_states: ["soc::queued"],
      tracker_terminal_states: ["soc::done"]
    )

    Application.put_env(:symphony_elixir, :gitlab_client_module, FakeGitLabClient)
    Application.put_env(:symphony_elixir, :gitlab_test_recipient, self())
    Webhook.reset_idempotency_for_test()
  end

  defp note_payload(note, opts \\ []) do
    %{
      "object_attributes" => %{
        "id" => Keyword.get(opts, :note_id, 1001),
        "note" => note,
        "noteable_type" => "Issue"
      },
      "issue" => %{
        "iid" => 42,
        "state" => Keyword.get(opts, :issue_state, "opened"),
        "labels" => Keyword.get(opts, :labels, ["soc::queued"])
      }
    }
  end
end
