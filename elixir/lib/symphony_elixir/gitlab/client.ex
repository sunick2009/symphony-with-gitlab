defmodule SymphonyElixir.GitLab.Client do
  @moduledoc """
  Thin GitLab REST client for issue polling and adapter-owned writeback.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @typep request_fun :: (atom(), String.t(), keyword() -> term())

  @per_page 100
  @max_error_body_log_bytes 1_000

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
    request(:post, "/issues/#{encode_path_segment(issue_iid)}/notes", json: %{"body" => body})
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
      request(:put, "/issues/#{encode_path_segment(issue_iid)}", json: payload)
      |> case do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status, body: response_body}} -> api_status_error(status, response_body)
        {:error, reason} -> {:error, reason}
      end
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

  defp derive_state(labels, issue_state, active_states, terminal_states) do
    normalized_labels = normalized_label_list(labels)

    cond do
      normalize_label(issue_state) == "closed" ->
        configured_label_match(labels, terminal_states) || "closed"

      terminal = configured_label_match_from_list(normalized_labels, terminal_states) ->
        terminal

      active = configured_label_match_from_list(normalized_labels, active_states) ->
        active

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
