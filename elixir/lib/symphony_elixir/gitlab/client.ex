defmodule SymphonyElixir.GitLab.Client do
  @moduledoc """
  Thin GitLab REST client for issue polling and adapter-owned writeback.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @typep request_fun :: (atom(), String.t(), keyword() -> term())

  @per_page 100
  @max_error_body_log_bytes 1_000
  @lifecycle_labels [
    "soc::queued",
    "soc::claimed",
    "soc::running",
    "soc::waiting-input",
    "soc::human-review",
    "soc::rework",
    "soc::failed",
    "soc::done"
  ]

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(tracker),
         {:ok, issues} <- fetch_issues_for_labels(tracker.active_states, state: "opened") do
      {:ok, dedupe_issues(issues)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    state_names
    |> normalize_configured_labels()
    |> case do
      [] -> {:ok, []}
      labels -> fetch_issues_for_labels(labels, scope: "all")
    end
    |> case do
      {:ok, issues} -> {:ok, dedupe_issues(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    iids =
      issue_ids
      |> Enum.map(&normalize_issue_iid/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case iids do
      [] -> {:ok, []}
      _ -> list_project_issues(%{"iids[]" => iids, "scope" => "all"})
    end
  end

  @spec post_issue_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def post_issue_comment(issue_iid, body) when is_binary(issue_iid) and is_binary(body) do
    writeback_request(:post, "/issues/#{encode_path_segment(issue_iid)}/notes", json: %{"body" => body})
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: response_body}} -> api_status_error(status, response_body)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_labels(String.t(), [String.t()], [String.t()]) :: :ok | {:error, term()}
  def update_issue_labels(issue_iid, add_labels, remove_labels)
      when is_binary(issue_iid) and is_list(add_labels) and is_list(remove_labels) do
    payload =
      %{}
      |> maybe_put_csv("add_labels", add_labels)
      |> maybe_put_csv("remove_labels", remove_labels)

    if payload == %{} do
      :ok
    else
      writeback_request(:put, "/issues/#{encode_path_segment(issue_iid)}", json: payload)
      |> case do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status, body: response_body}} -> api_status_error(status, response_body)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec fetch_branch(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def fetch_branch(branch_name) when is_binary(branch_name) do
    case request(:get, "/repository/branches/#{encode_path_segment(branch_name)}", []) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, normalize_branch(body)}

      {:ok, %{status: 404}} ->
        {:ok, nil}

      {:ok, %{status: status, body: response_body}} ->
        api_status_error(status, response_body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create_branch(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_branch(branch_name, ref) when is_binary(branch_name) and is_binary(ref) do
    writeback_request(:post, "/repository/branches", json: %{"branch" => branch_name, "ref" => ref})
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, normalize_branch(body)}

      {:ok, %{status: status, body: response_body}} ->
        api_status_error(status, response_body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create_commit(String.t(), String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def create_commit(branch_name, message, actions, opts \\ [])
      when is_binary(branch_name) and is_binary(message) and is_list(actions) do
    payload =
      %{
        "branch" => branch_name,
        "commit_message" => message,
        "actions" => Enum.map(actions, &normalize_commit_action/1)
      }
      |> maybe_put_string("start_branch", Keyword.get(opts, :start_branch))
      |> maybe_put_string("start_sha", Keyword.get(opts, :start_sha))
      |> maybe_put_string("author_email", Keyword.get(opts, :author_email))
      |> maybe_put_string("author_name", Keyword.get(opts, :author_name))

    writeback_request(:post, "/repository/commits", json: payload)
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, normalize_commit(body)}

      {:ok, %{status: status, body: response_body}} ->
        api_status_error(status, response_body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec fetch_open_merge_request(String.t(), String.t() | nil) :: {:ok, map() | nil} | {:error, term()}
  def fetch_open_merge_request(source_branch, target_branch \\ nil)
      when is_binary(source_branch) and (is_binary(target_branch) or is_nil(target_branch)) do
    params =
      %{
        "state" => "opened",
        "source_branch" => source_branch,
        "per_page" => 1
      }
      |> maybe_put_string("target_branch", target_branch)

    case request(:get, "/merge_requests", params: params) do
      {:ok, %{status: 200, body: [merge_request | _]}} when is_map(merge_request) ->
        {:ok, normalize_merge_request(merge_request)}

      {:ok, %{status: 200, body: []}} ->
        {:ok, nil}

      {:ok, %{status: status, body: response_body}} ->
        api_status_error(status, response_body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create_merge_request(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def create_merge_request(source_branch, target_branch, title, description \\ nil)
      when is_binary(source_branch) and is_binary(target_branch) and is_binary(title) do
    payload =
      %{
        "source_branch" => source_branch,
        "target_branch" => target_branch,
        "title" => title
      }
      |> maybe_put_string("description", description)

    writeback_request(:post, "/merge_requests", json: payload)
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, normalize_merge_request(body)}

      {:ok, %{status: status, body: response_body}} ->
        api_status_error(status, response_body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec fetch_merge_request_pipelines(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_merge_request_pipelines(merge_request_iid) when is_binary(merge_request_iid) do
    case request(:get, "/merge_requests/#{encode_path_segment(merge_request_iid)}/pipelines", []) do
      {:ok, %{status: 200, body: pipelines}} when is_list(pipelines) ->
        {:ok, Enum.map(pipelines, &normalize_pipeline/1)}

      {:ok, %{status: status, body: response_body}} ->
        api_status_error(status, response_body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(payload) when is_map(payload), do: normalize_issue(payload)

  @doc false
  @spec derived_state_for_test([String.t()], String.t() | nil, [String.t()], [String.t()]) :: String.t() | nil
  def derived_state_for_test(labels, issue_state, active_states, terminal_states) do
    derive_state(labels, issue_state, active_states, terminal_states)
  end

  @doc false
  @spec update_issue_labels_for_test(String.t(), [String.t()], [String.t()], request_fun()) ::
          :ok | {:error, term()}
  def update_issue_labels_for_test(issue_iid, add_labels, remove_labels, request_fun)
      when is_function(request_fun, 3) do
    with_temporary_request_fun(request_fun, fn ->
      update_issue_labels(issue_iid, add_labels, remove_labels)
    end)
  end

  @doc false
  @spec fetch_branch_for_test(String.t(), request_fun()) :: {:ok, map() | nil} | {:error, term()}
  def fetch_branch_for_test(branch_name, request_fun)
      when is_binary(branch_name) and is_function(request_fun, 3) do
    with_temporary_request_fun(request_fun, fn ->
      fetch_branch(branch_name)
    end)
  end

  @doc false
  @spec create_branch_for_test(String.t(), String.t(), request_fun()) :: {:ok, map()} | {:error, term()}
  def create_branch_for_test(branch_name, ref, request_fun)
      when is_binary(branch_name) and is_binary(ref) and is_function(request_fun, 3) do
    with_temporary_request_fun(request_fun, fn ->
      create_branch(branch_name, ref)
    end)
  end

  @doc false
  @spec create_commit_for_test(String.t(), String.t(), [map()], keyword(), request_fun()) ::
          {:ok, map()} | {:error, term()}
  def create_commit_for_test(branch_name, message, actions, opts, request_fun)
      when is_binary(branch_name) and is_binary(message) and is_list(actions) and is_list(opts) and
             is_function(request_fun, 3) do
    with_temporary_request_fun(request_fun, fn ->
      create_commit(branch_name, message, actions, opts)
    end)
  end

  @doc false
  @spec fetch_open_merge_request_for_test(String.t(), String.t() | nil, request_fun()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_merge_request_for_test(source_branch, target_branch, request_fun)
      when is_binary(source_branch) and (is_binary(target_branch) or is_nil(target_branch)) and
             is_function(request_fun, 3) do
    with_temporary_request_fun(request_fun, fn ->
      fetch_open_merge_request(source_branch, target_branch)
    end)
  end

  @doc false
  @spec create_merge_request_for_test(String.t(), String.t(), String.t(), String.t() | nil, request_fun()) ::
          {:ok, map()} | {:error, term()}
  def create_merge_request_for_test(source_branch, target_branch, title, description, request_fun)
      when is_binary(source_branch) and is_binary(target_branch) and is_binary(title) and
             (is_binary(description) or is_nil(description)) and is_function(request_fun, 3) do
    with_temporary_request_fun(request_fun, fn ->
      create_merge_request(source_branch, target_branch, title, description)
    end)
  end

  @doc false
  @spec fetch_merge_request_pipelines_for_test(String.t(), request_fun()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_merge_request_pipelines_for_test(merge_request_iid, request_fun)
      when is_binary(merge_request_iid) and is_function(request_fun, 3) do
    with_temporary_request_fun(request_fun, fn ->
      fetch_merge_request_pipelines(merge_request_iid)
    end)
  end

  defp fetch_issues_for_labels(labels, opts) when is_list(labels) do
    labels
    |> normalize_configured_labels()
    |> Enum.reduce_while({:ok, []}, fn label, {:ok, acc} ->
      params =
        opts
        |> Map.new()
        |> Map.put("labels", label)

      case list_project_issues(params) do
        {:ok, issues} -> {:cont, {:ok, issues ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp list_project_issues(params) when is_map(params) do
    list_project_issues_page(params, 1, [])
  end

  defp list_project_issues_page(params, page, acc) do
    params =
      params
      |> Map.put("per_page", @per_page)
      |> Map.put("page", page)

    case request(:get, "/issues", params: params) do
      {:ok, %{status: status, body: body} = response} when status in 200..299 and is_list(body) ->
        issues =
          body
          |> Enum.map(&normalize_issue/1)
          |> Enum.reject(&is_nil/1)

        updated_acc = acc ++ issues

        case next_page(response) do
          {:ok, next_page_number} -> list_project_issues_page(params, next_page_number, updated_acc)
          :done -> {:ok, updated_acc}
        end

      {:ok, %{status: status, body: response_body}} ->
        api_status_error(status, response_body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(method, project_path, opts) do
    request_fun = Application.get_env(:symphony_elixir, :gitlab_request_fun, &default_request/3)
    request_fun.(method, api_url(project_path), normalize_request_opts(opts))
  end

  defp writeback_request(method, project_path, opts) do
    max_attempts = Config.settings!().tracker.writeback_max_attempts
    base_backoff_ms = Config.settings!().tracker.writeback_base_backoff_ms
    do_writeback_request(method, project_path, opts, 1, max_attempts, base_backoff_ms)
  end

  defp do_writeback_request(method, project_path, opts, attempt, max_attempts, base_backoff_ms) do
    result = request(method, project_path, opts)

    if retryable_writeback_result?(result) and attempt < max_attempts do
      sleep_for_retry(attempt, base_backoff_ms)
      do_writeback_request(method, project_path, opts, attempt + 1, max_attempts, base_backoff_ms)
    else
      Process.put(:symphony_gitlab_writeback_attempts, attempt)
      result
    end
  end

  defp retryable_writeback_result?({:error, _reason}), do: true

  defp retryable_writeback_result?({:ok, %{status: status}})
       when status == 429 or status in 500..599,
       do: true

  defp retryable_writeback_result?(_result), do: false

  defp sleep_for_retry(_attempt, 0), do: :ok

  defp sleep_for_retry(attempt, base_backoff_ms) do
    Process.sleep(base_backoff_ms * Integer.pow(2, attempt - 1))
  end

  defp default_request(method, url, opts) do
    with {:ok, headers} <- rest_headers() do
      Req.request(
        Keyword.merge(opts,
          method: method,
          url: url,
          headers: headers,
          connect_options: [timeout: 30_000]
        )
      )
    end
  end

  defp normalize_request_opts(opts) do
    opts
    |> Keyword.update(:params, nil, &normalize_query_params/1)
    |> Keyword.reject(fn
      {:params, nil} -> true
      _ -> false
    end)
  end

  defp normalize_query_params(%{} = params) do
    if Enum.any?(params, fn {_key, value} -> is_list(value) end) do
      Enum.flat_map(params, fn
        {key, values} when is_list(values) -> Enum.map(values, &{key, &1})
        {key, value} -> [{key, value}]
      end)
    else
      params
    end
  end

  defp normalize_query_params(params), do: params

  defp maybe_put_string(payload, _key, nil), do: payload
  defp maybe_put_string(payload, _key, ""), do: payload
  defp maybe_put_string(payload, key, value) when is_binary(value), do: Map.put(payload, key, value)
  defp maybe_put_string(payload, _key, _value), do: payload

  defp normalize_commit_action(action) when is_map(action) do
    action
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
    |> Map.take(["action", "file_path", "previous_path", "content", "encoding", "execute_filemode", "last_commit_id"])
  end

  defp normalize_commit_action(action), do: action

  defp with_temporary_request_fun(request_fun, fun) do
    previous = Application.get_env(:symphony_elixir, :gitlab_request_fun)
    Application.put_env(:symphony_elixir, :gitlab_request_fun, request_fun)

    try do
      fun.()
    after
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :gitlab_request_fun)
        value -> Application.put_env(:symphony_elixir, :gitlab_request_fun, value)
      end
    end
  end

  defp rest_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_gitlab_api_token}

      token ->
        {:ok,
         [
           {"PRIVATE-TOKEN", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp validate_tracker_config(tracker) do
    cond do
      is_nil(tracker.api_key) -> {:error, :missing_gitlab_api_token}
      is_nil(tracker.project_slug) -> {:error, :missing_gitlab_project_slug}
      true -> :ok
    end
  end

  defp api_url(project_path) do
    tracker = Config.settings!().tracker
    endpoint = tracker.endpoint || "https://gitlab.com"
    base = String.trim_trailing(endpoint, "/")
    project = encode_path_segment(tracker.project_slug)
    base <> "/api/v4/projects/" <> project <> project_path
  end

  defp encode_path_segment(value) when is_binary(value), do: URI.encode_www_form(value)

  defp normalize_issue(%{} = payload) do
    labels = normalize_payload_labels(payload["labels"])
    settings = Config.settings!()

    %Issue{
      id: normalize_issue_iid(payload["iid"]),
      identifier: issue_identifier(payload),
      title: payload["title"],
      description: payload["description"],
      priority: parse_priority(payload["weight"]),
      state: derive_state(labels, payload["state"], settings.tracker.active_states, settings.tracker.terminal_states),
      branch_name: nil,
      url: payload["web_url"],
      assignee_id: assignee_id(payload),
      blocked_by: [],
      labels: Enum.map(labels, &String.downcase/1),
      assigned_to_worker: true,
      created_at: parse_datetime(payload["created_at"]),
      updated_at: parse_datetime(payload["updated_at"])
    }
  end

  defp normalize_issue(_payload), do: nil

  defp normalize_branch(%{} = payload) do
    %{
      "branch_name" => payload["name"],
      "name" => payload["name"],
      "merged" => payload["merged"],
      "protected" => payload["protected"],
      "default" => payload["default"],
      "web_url" => payload["web_url"],
      "commit_id" => get_in(payload, ["commit", "id"])
    }
  end

  defp normalize_commit(%{} = payload) do
    %{
      "commit_sha" => payload["id"],
      "id" => payload["id"],
      "short_id" => payload["short_id"],
      "title" => payload["title"],
      "message" => payload["message"],
      "web_url" => payload["web_url"]
    }
  end

  defp normalize_merge_request(%{} = payload) do
    %{
      "merge_request_iid" => normalize_issue_iid(payload["iid"]),
      "merge_request_url" => payload["web_url"],
      "iid" => normalize_issue_iid(payload["iid"]),
      "id" => payload["id"],
      "title" => payload["title"],
      "description" => payload["description"],
      "web_url" => payload["web_url"],
      "state" => payload["state"],
      "source_branch" => payload["source_branch"],
      "target_branch" => payload["target_branch"],
      "sha" => payload["sha"]
    }
  end

  defp normalize_pipeline(%{} = payload) do
    %{
      "id" => payload["id"],
      "sha" => payload["sha"],
      "ref" => payload["ref"],
      "status" => payload["status"],
      "web_url" => payload["web_url"],
      "updated_at" => payload["updated_at"]
    }
  end

  defp derive_state(labels, issue_state, active_states, terminal_states) do
    normalized_labels = normalized_label_list(labels)

    cond do
      normalize_label(issue_state) == "closed" ->
        configured_label_match(labels, terminal_states) || "closed"

      terminal = configured_label_match_from_list(normalized_labels, terminal_states) ->
        terminal

      active = configured_label_match_from_list(normalized_labels, active_states) ->
        active

      lifecycle = configured_label_match_from_list(normalized_labels, @lifecycle_labels) ->
        lifecycle

      true ->
        issue_state
    end
  end

  defp configured_label_match(labels, configured_labels) do
    configured_label_match_from_list(normalized_label_list(labels), configured_labels)
  end

  @spec configured_label_match_from_list([String.t()], [String.t()]) :: String.t() | nil
  defp configured_label_match_from_list(normalized_labels, configured_labels) do
    Enum.find(configured_labels, fn configured ->
      normalize_label(configured) in normalized_labels
    end)
  end

  @spec normalized_label_list(term()) :: [String.t()]
  defp normalized_label_list(labels) when is_list(labels) do
    labels
    |> Enum.map(&normalize_label/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalized_label_list(_labels), do: []

  defp normalize_payload_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_payload_labels(_labels), do: []

  defp normalize_configured_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(_label), do: ""

  defp normalize_issue_iid(iid) when is_integer(iid), do: Integer.to_string(iid)

  defp normalize_issue_iid(iid) when is_binary(iid) do
    trimmed = String.trim(iid)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_issue_iid(_iid), do: nil

  defp issue_identifier(%{"references" => %{"relative" => relative}}) when is_binary(relative), do: relative
  defp issue_identifier(%{"iid" => iid}), do: "#" <> to_string(iid)
  defp issue_identifier(_payload), do: nil

  defp assignee_id(%{"assignee" => %{"id" => id}}), do: to_string(id)
  defp assignee_id(%{"assignees" => [%{"id" => id} | _]}), do: to_string(id)
  defp assignee_id(_payload), do: nil

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp dedupe_issues(issues) when is_list(issues) do
    issues
    |> Enum.reduce(%{}, fn
      %Issue{id: id} = issue, acc when is_binary(id) -> Map.put_new(acc, id, issue)
      _issue, acc -> acc
    end)
    |> Map.values()
    |> Enum.sort_by(fn %Issue{id: id} -> id end)
  end

  defp maybe_put_csv(payload, key, values) do
    values =
      values
      |> normalize_configured_labels()
      |> Enum.join(",")

    if values == "", do: payload, else: Map.put(payload, key, values)
  end

  defp next_page(response) do
    response
    |> Req.Response.get_header("x-next-page")
    |> case do
      [next | _] when is_binary(next) and next != "" ->
        case Integer.parse(next) do
          {page, ""} when page > 0 -> {:ok, page}
          _ -> :done
        end

      _ ->
        :done
    end
  end

  defp api_status_error(status, body) do
    Logger.error("GitLab API request failed status=#{status} body=#{summarize_error_body(body)}")
    {:error, {:gitlab_api_status, status}}
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
