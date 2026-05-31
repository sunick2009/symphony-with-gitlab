defmodule SymphonyElixir.GitLab.StateStore do
  @moduledoc """
  File-backed GitLab control-plane audit and idempotency state.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config

  @schema_version 1
  @call_timeout 60_000

  @type writeback_fun :: (-> :ok | {:ok, map()} | {:error, term()})
  @type writeback_result :: :ok | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @impl true
  def init(state), do: {:ok, state}

  @spec begin_webhook_event(String.t(), map()) :: :ok | {:ok, :duplicate} | {:error, term()}
  def begin_webhook_event(event_key, attrs) when is_binary(event_key) and is_map(attrs) do
    call({:begin_webhook_event, state_path(), event_key, attrs})
  end

  @spec finish_webhook_event(String.t(), atom(), term()) :: :ok | {:error, term()}
  def finish_webhook_event(event_key, status, result) when is_binary(event_key) and is_atom(status) do
    call({:finish_webhook_event, state_path(), event_key, status, sanitize_result(result)})
  end

  @spec writeback_once(String.t(), map(), writeback_fun()) :: writeback_result()
  def writeback_once(operation_key, attrs, fun)
      when is_binary(operation_key) and is_map(attrs) and is_function(fun, 0) do
    call({:writeback_once, state_path(), operation_key, attrs, fun})
  end

  @spec record_issue_run_state(String.t(), String.t()) :: :ok | {:error, term()}
  def record_issue_run_state(issue_iid, lifecycle_state)
      when is_binary(issue_iid) and is_binary(lifecycle_state) do
    call({:record_issue_run_state, state_path(), issue_iid, lifecycle_state})
  end

  @spec record_issue_run_snapshot(String.t(), map()) :: :ok | {:error, term()}
  def record_issue_run_snapshot(issue_iid, attrs) when is_binary(issue_iid) and is_map(attrs) do
    call({:record_issue_run_snapshot, state_path(), issue_iid, attrs})
  end

  @spec record_ci_observation(String.t(), map()) :: :ok | {:error, term()}
  def record_ci_observation(issue_iid, attrs) when is_binary(issue_iid) and is_map(attrs) do
    call({:record_issue_run_snapshot, state_path(), issue_iid, attrs})
  end

  @spec fetch_issue_run_snapshot(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def fetch_issue_run_snapshot(issue_iid) when is_binary(issue_iid) do
    state_path()
    |> load_state()
    |> case do
      {:ok, state} -> {:ok, get_in(state, ["issue_runs", issue_iid])}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec state_path() :: Path.t()
  def state_path do
    settings = Config.settings!()

    case settings.tracker.state_path do
      path when is_binary(path) and path != "" ->
        Path.expand(path)

      _ ->
        settings.workspace.root
        |> Path.join(".gitlab-control-plane-state.json")
        |> Path.expand()
    end
  end

  @doc false
  @spec read_for_test() :: map()
  def read_for_test do
    state_path()
    |> load_state()
    |> case do
      {:ok, state} -> state
      {:error, reason} -> raise "failed to read GitLab state store: #{inspect(reason)}"
    end
  end

  @doc false
  @spec reset_for_test() :: :ok
  def reset_for_test do
    path = state_path()
    File.rm(path)
    :ok
  end

  @impl true
  def handle_call({:begin_webhook_event, path, event_key, attrs}, _from, state) do
    result =
      update_state(path, fn stored ->
        if Map.has_key?(stored["webhook_events"], event_key) do
          {{:ok, :duplicate}, stored}
        else
          event =
            attrs
            |> stringify_keys()
            |> Map.take(["event_type", "issue_iid", "source"])
            |> Map.merge(%{
              "status" => "processing",
              "first_seen_at" => timestamp(),
              "updated_at" => timestamp()
            })

          {:ok, put_in(stored, ["webhook_events", event_key], event)}
        end
      end)

    {:reply, result, state}
  end

  def handle_call({:finish_webhook_event, path, event_key, status, result}, _from, state) do
    reply =
      update_state(path, fn stored ->
        event = get_in(stored, ["webhook_events", event_key]) || %{"first_seen_at" => timestamp()}

        updated =
          event
          |> Map.put("status", Atom.to_string(status))
          |> Map.put("result", result)
          |> Map.put("updated_at", timestamp())

        {:ok, put_in(stored, ["webhook_events", event_key], updated)}
      end)

    {:reply, reply, state}
  end

  def handle_call({:writeback_once, path, operation_key, attrs, fun}, _from, state) do
    reply =
      with {:ok, stored} <- load_state(path),
           :pending <- prepare_writeback(stored, path, operation_key, attrs) do
        execute_writeback(path, operation_key, attrs, fun)
      else
        :done -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:record_issue_run_state, path, issue_iid, lifecycle_state}, _from, state) do
    reply =
      update_state(path, fn stored ->
        issue_run =
          (get_in(stored, ["issue_runs", issue_iid]) || %{})
          |> Map.put("lifecycle_state", lifecycle_state)
          |> Map.put("updated_at", timestamp())

        {:ok, put_in(stored, ["issue_runs", issue_iid], issue_run)}
      end)

    {:reply, reply, state}
  end

  def handle_call({:record_issue_run_snapshot, path, issue_iid, attrs}, _from, state) do
    reply =
      update_state(path, fn stored ->
        {:ok, put_issue_run_snapshot(stored, issue_iid, attrs)}
      end)

    {:reply, reply, state}
  end

  defp execute_writeback(path, operation_key, attrs, fun) do
    case fun.() do
      :ok ->
        update_writeback(path, operation_key, attrs, %{
          "status" => "done",
          "attempts" => writeback_attempts(attrs),
          "completed_at" => timestamp()
        })

      {:ok, metadata} when is_map(metadata) ->
        update_writeback(path, operation_key, attrs, %{
          "status" => "done",
          "attempts" => writeback_attempts(attrs),
          "completed_at" => timestamp(),
          "result_metadata" => stringify_keys(metadata)
        })

      {:error, reason} = error ->
        _ =
          update_writeback(path, operation_key, attrs, %{
            "status" => "failed",
            "attempts" => writeback_attempts(attrs),
            "reason" => sanitize_result(reason),
            "failed_at" => timestamp()
          })

        error
    end
  rescue
    error ->
      reason = Exception.message(error)

      _ =
        update_writeback(path, operation_key, attrs, %{
          "status" => "failed",
          "attempts" => writeback_attempts(attrs),
          "reason" => reason,
          "failed_at" => timestamp()
        })

      {:error, {:writeback_exception, reason}}
  end

  defp prepare_writeback(stored, path, operation_key, attrs) do
    if get_in(stored, ["writebacks", operation_key, "status"]) == "done" do
      :done
    else
      processing =
        attrs
        |> stringify_keys()
        |> Map.take([
          "operation",
          "issue_iid",
          "lifecycle_state",
          "comment_key",
          "run_fingerprint",
          "manifest_digest",
          "action_digest",
          "branch_name",
          "target_ref",
          "commit_message",
          "source_branch",
          "target_branch",
          "title",
          "merge_request_iid",
          "merge_request_url",
          "pipeline_id",
          "pipeline_status",
          "status_class",
          "ci_observed_at",
          "last_writeback_status_class"
        ])
        |> Map.merge(%{
          "status" => "processing",
          "attempts" => 0,
          "updated_at" => timestamp()
        })

      stored
      |> put_in(["writebacks", operation_key], processing)
      |> write_state(path)
      |> case do
        :ok -> :pending
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp update_writeback(path, operation_key, attrs, updates) do
    update_state(path, fn stored ->
      existing = get_in(stored, ["writebacks", operation_key]) || %{}

      writeback =
        attrs
        |> stringify_keys()
        |> Map.take([
          "operation",
          "issue_iid",
          "lifecycle_state",
          "comment_key",
          "run_fingerprint",
          "manifest_digest",
          "action_digest",
          "branch_name",
          "target_ref",
          "commit_message",
          "source_branch",
          "target_branch",
          "title",
          "merge_request_iid",
          "merge_request_url",
          "pipeline_id",
          "pipeline_status",
          "status_class",
          "ci_observed_at",
          "last_writeback_status_class"
        ])
        |> Map.merge(existing)
        |> Map.merge(updates)
        |> Map.put("updated_at", timestamp())

      stored = put_in(stored, ["writebacks", operation_key], writeback)

      stored =
        cond do
          writeback["status"] == "done" and writeback["operation"] == "transition" ->
            put_issue_run_state(stored, writeback["issue_iid"], writeback["lifecycle_state"])

          writeback["status"] == "done" ->
            put_issue_run_snapshot_from_writeback(stored, writeback)

          true ->
            stored
        end

      {:ok, stored}
    end)
  end

  defp put_issue_run_state(stored, issue_iid, lifecycle_state)
       when is_binary(issue_iid) and is_binary(lifecycle_state) do
    issue_run =
      (get_in(stored, ["issue_runs", issue_iid]) || %{})
      |> Map.put("lifecycle_state", lifecycle_state)
      |> Map.put("updated_at", timestamp())

    put_in(stored, ["issue_runs", issue_iid], issue_run)
  end

  defp put_issue_run_state(stored, _issue_iid, _lifecycle_state), do: stored

  defp put_issue_run_snapshot_from_writeback(stored, %{"issue_iid" => issue_iid} = writeback)
       when is_binary(issue_iid) do
    snapshot_attrs =
      %{}
      |> maybe_put_snapshot_field("run_fingerprint", writeback["run_fingerprint"])
      |> maybe_put_snapshot_field("branch_name", writeback["branch_name"])
      |> maybe_put_snapshot_field("target_ref", writeback["target_ref"])
      |> maybe_put_snapshot_field("source_branch", writeback["source_branch"])
      |> maybe_put_snapshot_field("target_branch", writeback["target_branch"])
      |> maybe_put_snapshot_field("merge_request_iid", writeback["merge_request_iid"])
      |> maybe_put_snapshot_field("merge_request_url", writeback["merge_request_url"])
      |> maybe_put_snapshot_field("pipeline_id", writeback["pipeline_id"])
      |> maybe_put_snapshot_field("pipeline_status", writeback["pipeline_status"])
      |> maybe_put_snapshot_field("status_class", writeback["status_class"])
      |> maybe_put_snapshot_field("ci_observed_at", writeback["ci_observed_at"])
      |> maybe_put_snapshot_field("last_writeback_status_class", writeback["last_writeback_status_class"])
      |> merge_result_metadata(Map.get(writeback, "result_metadata"))

    put_issue_run_snapshot(stored, issue_iid, snapshot_attrs)
  end

  defp put_issue_run_snapshot_from_writeback(stored, _writeback), do: stored

  defp put_issue_run_snapshot(stored, issue_iid, attrs) when is_binary(issue_iid) and is_map(attrs) do
    issue_run = get_in(stored, ["issue_runs", issue_iid]) || %{}
    stage4 = Map.get(issue_run, "stage4", %{})

    updated_stage4 =
      stage4
      |> Map.merge(stringify_keys(attrs))
      |> Map.put("updated_at", timestamp())

    issue_run =
      issue_run
      |> Map.put("stage4", updated_stage4)
      |> Map.put("updated_at", timestamp())

    put_in(stored, ["issue_runs", issue_iid], issue_run)
  end

  defp put_issue_run_snapshot(stored, _issue_iid, _attrs), do: stored

  defp maybe_put_snapshot_field(snapshot, _key, nil), do: snapshot
  defp maybe_put_snapshot_field(snapshot, _key, ""), do: snapshot
  defp maybe_put_snapshot_field(snapshot, key, value), do: Map.put(snapshot, key, value)

  defp merge_result_metadata(snapshot, metadata) when is_map(metadata), do: Map.merge(snapshot, metadata)
  defp merge_result_metadata(snapshot, _metadata), do: snapshot

  defp call(message) do
    case ensure_started() do
      {:ok, _pid} -> GenServer.call(__MODULE__, message, @call_timeout)
      {:error, {:already_started, _pid}} -> GenServer.call(__MODULE__, message, @call_timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> ensure_started_via_supervisor()
    end
  end

  defp ensure_started_via_supervisor do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        case Supervisor.restart_child(SymphonyElixir.Supervisor, __MODULE__) do
          {:ok, child_pid} when is_pid(child_pid) ->
            {:ok, child_pid}

          {:ok, child_pid, _info} when is_pid(child_pid) ->
            {:ok, child_pid}

          {:error, :running} ->
            wait_for_registered_process()

          {:error, :restarting} ->
            wait_for_registered_process()

          {:error, :not_found} ->
            start_link()

          {:error, {:already_started, child_pid}} when is_pid(child_pid) ->
            {:ok, child_pid}

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        start_link()
    end
  end

  defp wait_for_registered_process(attempt \\ 1)

  defp wait_for_registered_process(attempt) when attempt <= 20 do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        Process.sleep(10)
        wait_for_registered_process(attempt + 1)
    end
  end

  defp wait_for_registered_process(_attempt), do: start_link()

  defp update_state(path, fun) when is_function(fun, 1) do
    with {:ok, state} <- load_state(path),
         {reply, updated_state} <- normalize_update_result(fun.(state)),
         :ok <- write_state(updated_state, path) do
      reply
    end
  end

  defp normalize_update_result({reply, %{} = state}), do: {reply, state}
  defp normalize_update_result(other), do: {{:error, {:invalid_state_update, other}}, initial_state()}

  defp load_state(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = state} -> {:ok, normalize_state(state)}
          {:ok, _other} -> {:error, {:invalid_gitlab_state_file, path}}
          {:error, reason} -> {:error, {:invalid_gitlab_state_json, path, inspect(reason)}}
        end

      {:error, :enoent} ->
        {:ok, initial_state()}

      {:error, reason} ->
        {:error, {:gitlab_state_read_failed, path, reason}}
    end
  end

  defp write_state(state, path) do
    dir = Path.dirname(path)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         {:ok, encoded} <- Jason.encode(normalize_state(state), pretty: true),
         :ok <- File.write(tmp, encoded <> "\n"),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed writing GitLab control-plane state path=#{path}: #{inspect(reason)}")
        {:error, {:gitlab_state_write_failed, path, reason}}
    end
  end

  defp initial_state do
    %{
      "schema_version" => @schema_version,
      "webhook_events" => %{},
      "writebacks" => %{},
      "issue_runs" => %{}
    }
  end

  defp normalize_state(state) do
    initial_state()
    |> Map.merge(Map.take(state, ["schema_version", "webhook_events", "writebacks", "issue_runs"]))
    |> Map.put("schema_version", @schema_version)
    |> Map.update!("webhook_events", &normalize_map/1)
    |> Map.update!("writebacks", &normalize_map/1)
    |> Map.update!("issue_runs", &normalize_map/1)
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), sanitize_result(value)} end)
  end

  defp sanitize_result(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_result(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp sanitize_result(value) when is_integer(value), do: value
  defp sanitize_result(value) when is_boolean(value), do: value
  defp sanitize_result(nil), do: nil

  defp sanitize_result(value) when is_tuple(value) or is_list(value) or is_map(value) do
    value
    |> inspect(limit: 20, printable_limit: 500)
    |> String.slice(0, 500)
  end

  defp sanitize_result(value), do: value |> inspect() |> String.slice(0, 500)

  defp writeback_attempts(attrs) do
    case Process.delete(:symphony_gitlab_writeback_attempts) do
      attempts when is_integer(attempts) and attempts > 0 ->
        attempts

      _ ->
        Map.get(attrs, :attempts, Map.get(attrs, "attempts", 1))
    end
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
