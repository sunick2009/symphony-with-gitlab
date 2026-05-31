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
    def create_commit(branch_name, message, actions, opts)
        when is_binary(branch_name) and is_binary(message) and is_list(actions) do
      commit_sha = "sha-#{System.unique_integer([:positive])}"

      commit = %{
        "commit_sha" => commit_sha,
        "message" => message,
        "branch_name" => branch_name,
        "action_count" => length(actions)
      }

      put_in_remote_state([:commits, branch_name], commit)
      send(test_recipient(), {:gitlab_commit_created, branch_name, message, actions, opts})
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

  test "dry-run finalization plans valid artifacts without live gitlab mutation" do
    configure_mr_workflow_test()
    workspace = create_workspace_fixture!()

    write_manifest!(workspace, %{
      "version" => 1,
      "artifacts" => [
        %{
          "repository_path" => "elixir/lib/generated_stage4.ex",
          "workspace_source_path" => "out/generated_stage4.ex",
          "action" => "create",
          "description" => "generated file",
          "content_type" => "text/plain"
        }
      ]
    })

    write_workspace_file!(workspace, "out/generated_stage4.ex", "defmodule GeneratedStage4 do\nend\n")

    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    assert {:ok, {:planned, plan}} = MRWorkflow.finalize_dry_run(issue, workspace, [])
    assert plan.issue_iid == "42"
    assert plan.source_branch =~ "soc/issue-42/"
    assert plan.target_branch == "main"
    assert plan.no_op == false
    assert plan.would_create_branch == true
    assert plan.would_create_commit == true
    assert plan.would_create_merge_request == true
    assert plan.manifest_digest
    assert plan.collected_artifact_digest
    assert plan.action_digest
    assert length(plan.commit_actions) == 1
    assert hd(plan.commit_actions).file_path == "elixir/lib/generated_stage4.ex"

    refute_receive {:gitlab_branch_created, _, _}
    refute_receive {:gitlab_commit_created, _, _, _, _}
    refute_receive {:gitlab_merge_request_created, _, _, _}

    state = StateStore.read_for_test()
    assert state["issue_runs"]["42"]["stage4"]["stage4_status"] == "dry-run-planned"
    assert state["issue_runs"]["42"]["stage4"]["manifest_digest"] == plan.manifest_digest
    assert state["issue_runs"]["42"]["stage4"]["action_digest"] == plan.action_digest
  end

  test "live mutation remains disabled by default during issue finalization" do
    configure_mr_workflow_test()
    workspace = create_workspace_fixture!()

    write_manifest!(workspace, %{
      "version" => 1,
      "artifacts" => [
        %{
          "repository_path" => "elixir/lib/live_disabled.ex",
          "workspace_source_path" => "out/live_disabled.ex",
          "action" => "create"
        }
      ]
    })

    write_workspace_file!(workspace, "out/live_disabled.ex", "defmodule LiveDisabled do\nend\n")
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    assert {:ok, {:planned, plan}} = MRWorkflow.finalize_issue_completion(issue, workspace, [])
    assert plan.no_op == false

    refute_receive {:gitlab_branch_created, _, _}
    refute_receive {:gitlab_commit_created, _, _, _, _}
    refute_receive {:gitlab_merge_request_created, _, _, _}
  end

  test "dry-run finalization records no-op when the manifest is missing" do
    configure_mr_workflow_test()
    workspace = create_workspace_fixture!()
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    assert {:ok, {:noop, plan}} = MRWorkflow.finalize_dry_run(issue, workspace, [])
    assert plan.no_op == true
    assert plan.manifest_digest == nil
    assert plan.action_digest == nil

    state = StateStore.read_for_test()
    assert state["issue_runs"]["42"]["stage4"]["stage4_status"] == "no-op"
  end

  test "dry-run finalization rejects invalid json manifests" do
    configure_mr_workflow_test()
    workspace = create_workspace_fixture!()
    write_workspace_file!(workspace, MRWorkflow.manifest_relpath(), "{invalid json")
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    assert {:error, {:invalid_artifact_manifest_json, _reason}} =
             MRWorkflow.finalize_dry_run(issue, workspace, [])
  end

  test "dry-run finalization rejects invalid manifest shape" do
    configure_mr_workflow_test()
    workspace = create_workspace_fixture!()
    write_manifest!(workspace, %{"version" => 1, "artifacts" => [%{"action" => "create"}]})
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    assert {:error, {:invalid_artifact_entry, 0, :missing_repository_path}} =
             MRWorkflow.finalize_dry_run(issue, workspace, [])
  end

  test "dry-run finalization rejects absolute repository paths" do
    configure_mr_workflow_test()
    workspace = create_workspace_fixture!()

    write_manifest!(workspace, %{
      "version" => 1,
      "artifacts" => [
        %{
          "repository_path" => "/tmp/evil.txt",
          "workspace_source_path" => "out/evil.txt",
          "action" => "create"
        }
      ]
    })

    write_workspace_file!(workspace, "out/evil.txt", "evil")
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    assert {:error, {:repository_path, :absolute_path_rejected, "/tmp/evil.txt"}} =
             MRWorkflow.finalize_dry_run(issue, workspace, [])
  end

  test "dry-run finalization rejects path traversal" do
    configure_mr_workflow_test()
    workspace = create_workspace_fixture!()

    write_manifest!(workspace, %{
      "version" => 1,
      "artifacts" => [
        %{
          "repository_path" => "elixir/lib/ok.txt",
          "workspace_source_path" => "../escape.txt",
          "action" => "create"
        }
      ]
    })

    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    assert {:error, {:workspace_source_path, :path_traversal_rejected, "../escape.txt"}} =
             MRWorkflow.finalize_dry_run(issue, workspace, [])
  end

  test "dry-run finalization rejects .git paths" do
    configure_mr_workflow_test()
    workspace = create_workspace_fixture!()

    write_manifest!(workspace, %{
      "version" => 1,
      "artifacts" => [
        %{
          "repository_path" => ".git/config",
          "workspace_source_path" => "out/config",
          "action" => "create"
        }
      ]
    })

    write_workspace_file!(workspace, "out/config", "evil")
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    assert {:error, {:blocked_path_segment, ".git/config"}} =
             MRWorkflow.finalize_dry_run(issue, workspace, [])
  end

  test "dry-run finalization rejects disallowed repository output paths" do
    configure_mr_workflow_test()
    workspace = create_workspace_fixture!()

    write_manifest!(workspace, %{
      "version" => 1,
      "artifacts" => [
        %{
          "repository_path" => "tmp/generated.txt",
          "workspace_source_path" => "out/generated.txt",
          "action" => "create"
        }
      ]
    })

    write_workspace_file!(workspace, "out/generated.txt", "tmp")
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    assert {:error, {:disallowed_repo_path, "tmp/generated.txt"}} =
             MRWorkflow.finalize_dry_run(issue, workspace, [])
  end

  test "dry-run finalization rejects oversized files" do
    configure_mr_workflow_test()
    workspace = create_workspace_fixture!()
    oversized_content = String.duplicate("a", 32)

    write_manifest!(workspace, %{
      "version" => 1,
      "artifacts" => [
        %{
          "repository_path" => "elixir/lib/large.txt",
          "workspace_source_path" => "out/large.txt",
          "action" => "create"
        }
      ]
    })

    write_workspace_file!(workspace, "out/large.txt", oversized_content)
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    assert {:error, {:artifact_too_large, "out/large.txt", 32, 16}} =
             MRWorkflow.finalize_dry_run(issue, workspace, max_artifact_bytes: 16)
  end

  test "dry-run finalization computes deterministic manifest and action digests" do
    configure_mr_workflow_test()
    workspace = create_workspace_fixture!()
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    manifest = %{
      "version" => 1,
      "artifacts" => [
        %{
          "repository_path" => "elixir/lib/generated_stage4.ex",
          "workspace_source_path" => "out/generated_stage4.ex",
          "action" => "create"
        }
      ]
    }

    write_manifest!(workspace, manifest)
    write_workspace_file!(workspace, "out/generated_stage4.ex", "defmodule GeneratedStage4 do\nend\n")

    assert {:ok, {:planned, first_plan}} = MRWorkflow.finalize_dry_run(issue, workspace, [])
    assert {:ok, {:planned, second_plan}} = MRWorkflow.finalize_dry_run(issue, workspace, [])
    assert first_plan.manifest_digest == second_plan.manifest_digest
    assert first_plan.action_digest == second_plan.action_digest
  end

  test "dry-run finalization is idempotent with the same digest and reports conflicts for changed digests" do
    configure_mr_workflow_test()
    workspace = create_workspace_fixture!()
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    write_manifest!(workspace, %{
      "version" => 1,
      "artifacts" => [
        %{
          "repository_path" => "elixir/lib/generated_stage4.ex",
          "workspace_source_path" => "out/generated_stage4.ex",
          "action" => "create"
        }
      ]
    })

    write_workspace_file!(workspace, "out/generated_stage4.ex", "defmodule GeneratedStage4 do\nend\n")

    assert {:ok, {:planned, first_plan}} = MRWorkflow.finalize_dry_run(issue, workspace, [])
    assert {:ok, {:planned, second_plan}} = MRWorkflow.finalize_dry_run(issue, workspace, [])
    assert first_plan.action_digest == second_plan.action_digest

    write_workspace_file!(workspace, "out/generated_stage4.ex", "defmodule GeneratedStage4 do\n  @x 1\nend\n")

    assert {:error, {:dry_run_conflict, "42", conflict}} =
             MRWorkflow.finalize_dry_run(issue, workspace, [])

    assert conflict[:previous_action_digest] == first_plan.action_digest
    refute conflict[:next_action_digest] == first_plan.action_digest
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

    assert_receive {:gitlab_commit_created, "soc/issue-42/run-commit", "feat: update file", ^actions, []}

    assert :ok =
             Adapter.create_commit_once(
               "42",
               "run-commit",
               "soc/issue-42/run-commit",
               "feat: update file",
               actions,
               []
             )

    refute_receive {:gitlab_commit_created, "soc/issue-42/run-commit", "feat: update file", ^actions, []}

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

  test "live mutation executes branch commit mr and link writeback when staging-live is enabled" do
    configure_mr_workflow_test(
      tracker_stage4_live_mutation: true,
      tracker_stage4_allowed_project_slugs: ["group/project"]
    )

    workspace = create_workspace_fixture!()

    write_manifest!(workspace, %{
      "version" => 1,
      "artifacts" => [
        %{
          "repository_path" => "elixir/lib/live_enabled.ex",
          "workspace_source_path" => "out/live_enabled.ex",
          "action" => "create"
        }
      ]
    })

    write_workspace_file!(workspace, "out/live_enabled.ex", "defmodule LiveEnabled do\nend\n")
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    assert {:ok, {:executed, plan, stage4_snapshot}} =
             MRWorkflow.finalize_issue_completion(issue, workspace, [])

    assert_receive {:gitlab_branch_created, branch_name, "main"}
    assert branch_name == plan.source_branch
    assert_receive {:gitlab_commit_created, ^branch_name, _, _, opts}
    refute Keyword.has_key?(opts, :start_branch)
    assert_receive {:gitlab_merge_request_created, ^branch_name, "main", _title}
    assert_receive {:gitlab_comment, "42", body}
    assert body =~ "merge request"

    assert stage4_snapshot["stage4_status"] == "live-mr-created"
    assert stage4_snapshot["merge_request_url"] =~ "/merge_requests/"
    assert stage4_snapshot["commit_sha"] =~ "sha-"
  end

  test "live mutation guard blocks non-allowlisted projects" do
    configure_mr_workflow_test(
      tracker_stage4_live_mutation: true,
      tracker_stage4_allowed_project_slugs: ["group/disposable-only"]
    )

    workspace = create_workspace_fixture!()

    write_manifest!(workspace, %{
      "version" => 1,
      "artifacts" => [
        %{
          "repository_path" => "elixir/lib/live_guard.ex",
          "workspace_source_path" => "out/live_guard.ex",
          "action" => "create"
        }
      ]
    })

    write_workspace_file!(workspace, "out/live_guard.ex", "defmodule LiveGuard do\nend\n")
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    assert {:error, {:stage4_live_project_not_allowlisted, "group/project"}} =
             MRWorkflow.finalize_issue_completion(issue, workspace, [])

    refute_receive {:gitlab_branch_created, _, _}
    refute_receive {:gitlab_commit_created, _, _, _, _}
    refute_receive {:gitlab_merge_request_created, _, _, _}
  end

  test "live mutation reuses an existing branch and merge request idempotently" do
    configure_mr_workflow_test(
      tracker_stage4_live_mutation: true,
      tracker_stage4_allowed_project_slugs: ["group/project"]
    )

    workspace = create_workspace_fixture!()

    write_manifest!(workspace, %{
      "version" => 1,
      "artifacts" => [
        %{
          "repository_path" => "elixir/lib/live_reuse.ex",
          "workspace_source_path" => "out/live_reuse.ex",
          "action" => "create"
        }
      ]
    })

    write_workspace_file!(workspace, "out/live_reuse.ex", "defmodule LiveReuse do\nend\n")
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    assert {:ok, {:planned, plan}} = MRWorkflow.finalize_dry_run(issue, workspace, [])
    source_branch = plan.source_branch

    remote_put([:branches, source_branch], %{
      "branch_name" => source_branch,
      "name" => source_branch,
      "commit_id" => "main"
    })

    remote_put([:merge_requests, "88"], %{
      "merge_request_iid" => "88",
      "merge_request_url" => "https://gitlab.example.com/group/project/-/merge_requests/88",
      "source_branch" => source_branch,
      "target_branch" => "main",
      "title" => plan.merge_request_title,
      "description" => plan.merge_request_description,
      "state" => "opened"
    })

    assert {:ok, {:executed, _plan, stage4_snapshot}} =
             MRWorkflow.finalize_issue_completion(issue, workspace, [])

    refute_receive {:gitlab_branch_created, ^source_branch, "main"}
    assert_receive {:gitlab_commit_created, ^source_branch, _, _, opts}
    refute Keyword.has_key?(opts, :start_branch)
    refute_receive {:gitlab_merge_request_created, ^source_branch, "main", _}
    assert_receive {:gitlab_comment, "42", body}
    assert body =~ "/merge_requests/88"
    assert stage4_snapshot["merge_request_iid"] == "88"
  end

  test "live mutation blocks changed digest retries for the same run fingerprint" do
    configure_mr_workflow_test(
      tracker_stage4_live_mutation: true,
      tracker_stage4_allowed_project_slugs: ["group/project"]
    )

    workspace = create_workspace_fixture!()
    issue = %Issue{id: "42", identifier: "#42", title: "Generated update", state: "soc::running"}

    write_manifest!(workspace, %{
      "version" => 1,
      "artifacts" => [
        %{
          "repository_path" => "elixir/lib/live_conflict.ex",
          "workspace_source_path" => "out/live_conflict.ex",
          "action" => "create"
        }
      ]
    })

    write_workspace_file!(workspace, "out/live_conflict.ex", "defmodule LiveConflict do\nend\n")

    assert {:ok, {:executed, first_plan, _snapshot}} =
             MRWorkflow.finalize_issue_completion(issue, workspace, [])

    assert_receive {:gitlab_commit_created, branch_name, _, _, opts}
    assert branch_name == first_plan.source_branch
    refute Keyword.has_key?(opts, :start_branch)

    write_workspace_file!(workspace, "out/live_conflict.ex", "defmodule LiveConflict do\n  @x 1\nend\n")

    assert {:error, {:dry_run_conflict, "42", _conflict}} =
             MRWorkflow.finalize_issue_completion(issue, workspace, [])

    refute_receive {:gitlab_commit_created, ^branch_name, _, _, _}
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

  defp configure_mr_workflow_test(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "gitlab",
          tracker_endpoint: "https://gitlab.example.com",
          tracker_api_token: "token",
          tracker_project_slug: "group/project",
          tracker_webhook_secret: "secret",
          tracker_state_path: unique_gitlab_state_path(),
          tracker_active_states: ["soc::queued"],
          tracker_terminal_states: ["soc::done", "soc::failed"]
        ],
        overrides
      )
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

  defp create_workspace_fixture! do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-stage4-workspace-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    workspace
  end

  defp write_manifest!(workspace, manifest) do
    write_workspace_file!(workspace, MRWorkflow.manifest_relpath(), Jason.encode!(manifest))
  end

  defp write_workspace_file!(workspace, relpath, contents) do
    path = Path.join(workspace, relpath)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end
end
