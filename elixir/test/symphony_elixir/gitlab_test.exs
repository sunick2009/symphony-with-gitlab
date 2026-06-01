defmodule SymphonyElixir.GitLabTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitLab.{Adapter, Audit, Client, Command, StateStore, Webhook}

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

  test "gitlab issue normalization preserves controlled running lifecycle state" do
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
        "labels" => ["soc::running"]
      })

    assert issue.state == "soc::running"
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

  test "gitlab adapter lifecycle transitions are idempotent across state store restart" do
    configure_gitlab_webhook_test()

    assert :ok = Adapter.update_issue_state_once("42", "soc::running")
    assert_receive {:gitlab_labels, "42", ["soc::running"], _removed_labels}

    restart_gitlab_state_store()

    assert :ok = Adapter.update_issue_state_once("42", "soc::running")
    refute_receive {:gitlab_labels, "42", _add, _remove}
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

  test "gitlab client retries retryable writeback failures before success" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "token",
      tracker_project_slug: "group/project",
      tracker_writeback_max_attempts: 3,
      tracker_writeback_base_backoff_ms: 0
    )

    test_pid = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    request_fun = fn :put, _url, _opts ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
      send(test_pid, {:gitlab_writeback_attempt, attempt})

      if attempt < 3 do
        {:ok, %{status: 500, body: %{"message" => "temporary"}}}
      else
        {:ok, %{status: 200, body: %{}}}
      end
    end

    assert :ok =
             Client.update_issue_labels_for_test(
               "42",
               ["soc::queued"],
               [],
               request_fun
             )

    assert_receive {:gitlab_writeback_attempt, 1}
    assert_receive {:gitlab_writeback_attempt, 2}
    assert_receive {:gitlab_writeback_attempt, 3}
  end

  test "gitlab adapter records exhausted writeback retries in persistent state" do
    state_path = unique_gitlab_state_path()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "token",
      tracker_project_slug: "group/project",
      tracker_state_path: state_path,
      tracker_writeback_max_attempts: 2,
      tracker_writeback_base_backoff_ms: 0
    )

    request_fun = fn :put, _url, _opts ->
      {:ok, %{status: 500, body: %{"message" => "temporary"}}}
    end

    previous = Application.get_env(:symphony_elixir, :gitlab_request_fun)
    Application.put_env(:symphony_elixir, :gitlab_request_fun, request_fun)
    StateStore.reset_for_test()

    try do
      assert {:error, {:gitlab_api_status, 500}} = Adapter.update_issue_state_once("42", "soc::running")

      state = StateStore.read_for_test()
      writeback = state["writebacks"]["issue:42:transition:soc::running"]
      assert writeback["status"] == "failed"
      assert writeback["attempts"] == 2
      assert writeback["operation"] == "transition"
      assert writeback["issue_iid"] == "42"
    after
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :gitlab_request_fun)
        value -> Application.put_env(:symphony_elixir, :gitlab_request_fun, value)
      end
    end
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

  test "gitlab issue refresh expands list query parameters for repeated iid filters" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com",
      tracker_api_token: "token",
      tracker_project_slug: "group/project"
    )

    request_fun = fn :get, _url, opts ->
      send(self(), {:gitlab_refresh_params, opts[:params]})

      {:ok,
       %Req.Response{
         status: 200,
         headers: %{"x-next-page" => []},
         body: []
       }}
    end

    previous = Application.get_env(:symphony_elixir, :gitlab_request_fun)
    Application.put_env(:symphony_elixir, :gitlab_request_fun, request_fun)

    try do
      assert {:ok, []} = Client.fetch_issue_states_by_ids(["1", "2"])

      assert_receive {:gitlab_refresh_params, params}
      assert {"iids[]", "1"} in params
      assert {"iids[]", "2"} in params
      assert {"scope", "all"} in params
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
    assert :ignore = Command.parse("Please run /agent run later")
    assert :ignore = Command.parse("/soccer run")
    assert :ignore = Command.parse("/agentic run")
    assert {:ok, [%Command{name: "run"}]} = Command.parse("/soc run\nnormal text")
    assert {:ok, [%Command{name: "run", raw: "/agent run"}]} = Command.parse("/agent run\nnormal text")
    assert {:ok, [%Command{name: "status"}]} = Command.parse("intro\n/soc status")
    assert {:ok, [%Command{name: "status", raw: "/agent status"}]} = Command.parse("intro\n/agent status")
    assert {:error, {:unknown_command, "dance"}} = Command.parse("/soc dance")
    assert {:error, {:unknown_command, "dance"}} = Command.parse("/agent dance")
  end

  test "webhook rejects missing and invalid secrets before writeback" do
    configure_gitlab_webhook_test()

    base_headers = %{
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-secret"
    }

    assert {:error, :missing_gitlab_webhook_token} = Webhook.handle(base_headers, note_payload("/agent run"))
    assert {:error, :invalid_gitlab_webhook_token} = Webhook.handle(Map.put(base_headers, "x-gitlab-token", "wrong"), note_payload("/agent run"))
    refute_receive {:gitlab_labels, "42", _add, _remove}
    refute_receive {:gitlab_comment, "42", _body}
  end

  test "webhook handles agent run with secret validation, idempotency, comment writeback, and label transition" do
    configure_gitlab_webhook_test()

    headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-1"
    }

    assert {:ok, :handled} = Webhook.handle(headers, note_payload("/agent run"))

    assert_receive {:gitlab_labels, "42", ["soc::queued"], removed_labels}
    assert "soc::running" in removed_labels
    assert_receive {:gitlab_comment, "42", "Symphony accepted `/agent run` and queued this issue for an agent run."}

    assert {:ok, :duplicate} = Webhook.handle(headers, note_payload("/agent run"))
    refute_receive {:gitlab_labels, "42", _add, _remove}
    refute_receive {:gitlab_comment, "42", _body}

    events = Audit.list_events(issue_iid: "42")
    event_types = Enum.map(events, & &1["event_type"])
    command_event = Enum.find(events, &(&1["event_type"] == "command.parsed"))

    assert "webhook.received" in event_types
    assert "command.parsed" in event_types
    assert "issue.queued" in event_types
    assert "duplicate.suppressed" in event_types
    assert get_in(command_event, ["details", "command_name"]) == "run"
    assert get_in(command_event, ["details", "command_raw"]) == "/agent run"
  end

  test "webhook keeps soc run as a backward-compatible alias" do
    configure_gitlab_webhook_test()

    headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-soc-alias"
    }

    assert {:ok, :handled} = Webhook.handle(headers, note_payload("/soc run"))

    assert_receive {:gitlab_labels, "42", ["soc::queued"], _removed_labels}
    assert_receive {:gitlab_comment, "42", "Symphony accepted `/agent run` and queued this issue for an agent run."}

    command_event =
      Audit.list_events(issue_iid: "42")
      |> Enum.find(&(&1["event_type"] == "command.parsed"))

    assert get_in(command_event, ["details", "command_name"]) == "run"
    assert get_in(command_event, ["details", "command_raw"]) == "/soc run"
  end

  test "webhook replay remains suppressed after state store restart" do
    configure_gitlab_webhook_test()

    headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-persistent-replay"
    }

    assert {:ok, :handled} = Webhook.handle(headers, note_payload("/agent run"))
    assert_receive {:gitlab_labels, "42", ["soc::queued"], _removed_labels}
    assert_receive {:gitlab_comment, "42", "Symphony accepted `/agent run` and queued this issue for an agent run."}

    restart_gitlab_state_store()

    assert {:ok, :duplicate} = Webhook.handle(headers, note_payload("/agent run"))
    refute_receive {:gitlab_labels, "42", _add, _remove}
    refute_receive {:gitlab_comment, "42", _body}

    state = StateStore.read_for_test()
    assert state["webhook_events"]["note:1001"]["status"] == "handled"
  end

  test "webhook rejects duplicate run commands for active or terminal lifecycle issues" do
    configure_gitlab_webhook_test()

    for {label, index} <- Enum.with_index(["soc::queued", "soc::claimed", "soc::running", "soc::waiting-input", "soc::human-review", "soc::failed", "soc::done"]) do
      headers = %{
        "x-gitlab-token" => "secret",
        "x-gitlab-event" => "Note Hook",
        "x-gitlab-event-uuid" => "event-lifecycle-#{index}"
      }

      assert {:error, :issue_already_in_lifecycle} =
               Webhook.handle(headers, note_payload("/agent run", labels: [label], note_id: 2000 + index))

      assert_receive {:gitlab_comment, "42", "Symphony cannot queue this issue because it is already in a Symphony lifecycle state."}
      refute_receive {:gitlab_labels, "42", _add, _remove}
    end

    events = Audit.list_events(issue_iid: "42")
    assert Enum.any?(events, &(&1["event_type"] == "duplicate.suppressed"))
  end

  test "duplicate suppression works across agent and soc run aliases" do
    configure_gitlab_webhook_test()

    first_headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-cross-alias-1"
    }

    second_headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-cross-alias-2"
    }

    assert {:ok, :handled} = Webhook.handle(first_headers, note_payload("/agent run", note_id: 3001))
    assert_receive {:gitlab_labels, "42", ["soc::queued"], _removed_labels}
    assert_receive {:gitlab_comment, "42", "Symphony accepted `/agent run` and queued this issue for an agent run."}

    assert {:error, :issue_already_in_lifecycle} =
             Webhook.handle(second_headers, note_payload("/soc run", labels: ["soc::queued"], note_id: 3002))

    assert_receive {:gitlab_comment, "42", "Symphony cannot queue this issue because it is already in a Symphony lifecycle state."}
    refute_receive {:gitlab_labels, "42", _add, _remove}
  end

  test "duplicate suppression works across soc and agent run aliases" do
    configure_gitlab_webhook_test()

    first_headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-cross-alias-3"
    }

    second_headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-cross-alias-4"
    }

    assert {:ok, :handled} = Webhook.handle(first_headers, note_payload("/soc run", note_id: 3003))
    assert_receive {:gitlab_labels, "42", ["soc::queued"], _removed_labels}
    assert_receive {:gitlab_comment, "42", "Symphony accepted `/agent run` and queued this issue for an agent run."}

    assert {:error, :issue_already_in_lifecycle} =
             Webhook.handle(second_headers, note_payload("/agent run", labels: ["soc::queued"], note_id: 3004))

    assert_receive {:gitlab_comment, "42", "Symphony cannot queue this issue because it is already in a Symphony lifecycle state."}
    refute_receive {:gitlab_labels, "42", _add, _remove}
  end

  test "audit events redact secret-like fields and omit content bodies" do
    configure_gitlab_webhook_test()

    :ok =
      Audit.emit("secret.check", %{
        "issue_iid" => "42",
        "api_token" => "glpat-secret-value",
        "webhook_secret" => "top-secret",
        "prompt" => "do not keep",
        "artifact_content" => "full artifact body",
        "auth_headers" => %{"authorization" => "Bearer glpat-inner-secret"},
        ".env_snapshot" => "GITLAB_API_TOKEN=inline-token",
        "note" => "token=[glpat-visible] GITLAB_API_TOKEN=inline-token GITLAB_WEBHOOK_SECRET=inline-secret",
        "safe_field" => "kept"
      })

    [event] =
      Audit.list_events(issue_iid: "42")
      |> Enum.filter(&(&1["event_type"] == "secret.check"))

    details = event["details"]
    timeline = Audit.format_timeline([event])

    assert details["safe_field"] == "kept"
    assert details["note"] =~ "[REDACTED]"
    refute Map.has_key?(details, "api_token")
    refute Map.has_key?(details, "webhook_secret")
    refute Map.has_key?(details, "prompt")
    refute Map.has_key?(details, "artifact_content")
    refute Map.has_key?(details, "auth_headers")
    refute Map.has_key?(details, ".env_snapshot")
    refute inspect(event) =~ "glpat-secret-value"
    refute inspect(event) =~ "top-secret"
    refute inspect(event) =~ "inline-token"
    refute inspect(event) =~ "inline-secret"
    refute timeline =~ "glpat-secret-value"
    refute timeline =~ "GITLAB_API_TOKEN=inline-token"
    refute timeline =~ "GITLAB_WEBHOOK_SECRET=inline-secret"
  end

  test "audit logs expose structured logger metadata fields" do
    configure_gitlab_webhook_test()

    {:ok, context} = Audit.start_trace("42", "run-logger", %{run_fingerprint: "fp-logger"})

    log =
      capture_log(
        [metadata: [:gitlab_audit_event, :trace_id, :run_id, :issue_iid, :run_fingerprint], format: "$metadata $message\n"],
        fn ->
          :ok = Audit.emit("logger.check", %{issue_iid: "42"})
        end
      )

    assert log =~ "gitlab_audit_event=logger.check"
    assert log =~ "trace_id=#{context["trace_id"]}"
    assert log =~ "run_id=run-logger"
    assert log =~ "issue_iid=42"
    assert log =~ "run_fingerprint=fp-logger"
  end

  test "audit events are serialized as ordered valid JSONL" do
    configure_gitlab_webhook_test()

    {:ok, _context} = Audit.start_trace("42", "run-order", %{run_fingerprint: "fp-order"})

    :ok = Audit.emit("order.one", %{issue_iid: "42", sequence: 1})
    :ok = Audit.emit("order.two", %{issue_iid: "42", sequence: 2})
    :ok = Audit.emit("order.three", %{issue_iid: "42", sequence: 3})

    events =
      StateStore.read_audit_events()
      |> Enum.filter(&(&1["issue_iid"] == "42"))

    assert Enum.map(events, & &1["event_type"]) == ["order.one", "order.two", "order.three"]
    assert Enum.map(events, &get_in(&1, ["details", "sequence"])) == [1, 2, 3]
  end

  test "webhook parses recognized but unimplemented commands without dispatching" do
    configure_gitlab_webhook_test()

    headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-2"
    }

    assert {:ok, :handled} = Webhook.handle(headers, note_payload("/agent status"))
    assert_receive {:gitlab_comment, "42", "The `/agent status` command is recognized but is not implemented yet."}
    refute_receive {:gitlab_labels, "42", _add, _remove}
  end

  test "webhook reports unsupported agent-prefixed commands with the original command surface" do
    configure_gitlab_webhook_test()

    headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-unsupported-agent"
    }

    assert {:ok, :handled} = Webhook.handle(headers, note_payload("/agent dance"))
    assert_receive {:gitlab_comment, "42", "Unsupported Symphony command: `/agent dance`."}

    command_event =
      Audit.list_events(issue_iid: "42")
      |> Enum.find(&(&1["event_type"] == "command.parsed" and get_in(&1, ["details", "result"]) == "unsupported"))

    assert get_in(command_event, ["details", "command_name"]) == "dance"
    assert get_in(command_event, ["details", "command_raw"]) == "/agent dance"
  end

  test "webhook rejects closed issues with an adapter-owned comment" do
    configure_gitlab_webhook_test()

    headers = %{
      "x-gitlab-token" => "secret",
      "x-gitlab-event" => "Note Hook",
      "x-gitlab-event-uuid" => "event-3"
    }

    assert {:error, :closed_issue} = Webhook.handle(headers, note_payload("/agent run", issue_state: "closed"))
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
      tracker_state_path: unique_gitlab_state_path(),
      tracker_active_states: ["soc::queued"],
      tracker_terminal_states: ["soc::done"]
    )

    Application.put_env(:symphony_elixir, :gitlab_client_module, FakeGitLabClient)
    Application.put_env(:symphony_elixir, :gitlab_test_recipient, self())
    Webhook.reset_idempotency_for_test()
  end

  defp restart_gitlab_state_store do
    case Process.whereis(StateStore) do
      pid when is_pid(pid) ->
        GenServer.stop(pid)

      nil ->
        :ok
    end
  end

  defp unique_gitlab_state_path do
    Path.join(System.tmp_dir!(), "symphony-gitlab-state-#{System.unique_integer([:positive])}.json")
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
        "labels" => Keyword.get(opts, :labels, [])
      }
    }
  end
end
