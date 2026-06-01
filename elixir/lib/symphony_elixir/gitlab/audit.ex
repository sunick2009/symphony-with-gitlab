defmodule SymphonyElixir.GitLab.Audit do
  @moduledoc """
  Minimal structured audit emission and timeline query helpers for the GitLab
  control plane.
  """

  require Logger

  alias SymphonyElixir.GitLab.StateStore

  @schema_version 1
  @redacted "[REDACTED]"
  @redacted_key_fragments [
    "token",
    "secret",
    "prompt",
    "content",
    "auth",
    "api_key",
    ".env"
  ]

  @spec start_trace(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def start_trace(issue_iid, run_id, attrs \\ %{})
      when is_binary(issue_iid) and is_binary(run_id) and is_map(attrs) do
    trace_id = trace_id(issue_iid, run_id)

    context =
      attrs
      |> Map.take([:issue_iid, :run_id, :trace_id, :run_fingerprint, :source, :event_key])
      |> Map.merge(%{
        issue_iid: issue_iid,
        run_id: run_id,
        trace_id: trace_id
      })

    with :ok <- StateStore.record_issue_audit_context(issue_iid, context) do
      {:ok, stringify_keys(context)}
    end
  end

  @spec update_trace(String.t(), map()) :: :ok | {:error, term()}
  def update_trace(issue_iid, attrs) when is_binary(issue_iid) and is_map(attrs) do
    StateStore.record_issue_audit_context(issue_iid, attrs)
  end

  @spec context(String.t() | nil) :: map()
  def context(issue_iid) when is_binary(issue_iid) do
    case StateStore.fetch_issue_audit_context(issue_iid) do
      {:ok, audit_context} -> audit_context
      {:error, _reason} -> %{}
    end
  end

  def context(_issue_iid), do: %{}

  @spec emit(String.t(), map(), keyword()) :: :ok
  def emit(event_type, attrs \\ %{}, opts \\ [])
      when is_binary(event_type) and is_map(attrs) and is_list(opts) do
    level = Keyword.get(opts, :level, :info)
    issue_iid = get_issue_iid(attrs)
    merged = merge_correlation(issue_iid, attrs)

    event =
      %{
        schema_version: @schema_version,
        event_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        event_type: event_type,
        source: Map.get(merged, "source") || "gitlab"
      }
      |> Map.merge(Map.take(merged, ["trace_id", "run_id", "issue_iid", "run_fingerprint"]))
      |> Map.put("details", event_details(merged))

    metadata = [
      gitlab_audit_event: event_type,
      trace_id: event["trace_id"],
      run_id: event["run_id"],
      issue_iid: event["issue_iid"],
      run_fingerprint: event["run_fingerprint"]
    ]

    Logger.log(level, "gitlab_audit_event", Enum.reject(metadata, fn {_k, v} -> is_nil(v) end))

    case StateStore.append_audit_event(event) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("GitLab audit emission failed event_type=#{event_type} reason=#{inspect(reason)}")
        :ok
    end
  end

  @spec list_events(keyword()) :: [map()]
  def list_events(opts \\ []) when is_list(opts) do
    issue_iid = Keyword.get(opts, :issue_iid)
    trace_id = Keyword.get(opts, :trace_id)

    StateStore.read_audit_events()
    |> Enum.filter(fn event ->
      issue_match? =
        is_nil(issue_iid) or Map.get(event, "issue_iid") == issue_iid

      trace_match? =
        is_nil(trace_id) or Map.get(event, "trace_id") == trace_id

      issue_match? and trace_match?
    end)
    |> Enum.with_index()
    |> Enum.sort_by(fn {event, index} -> {Map.get(event, "event_at", ""), index} end)
    |> Enum.map(fn {event, _index} -> event end)
  end

  @spec format_timeline([map()]) :: String.t()
  def format_timeline(events) when is_list(events) do
    events
    |> Enum.map(fn event ->
      details =
        event
        |> Map.get("details", %{})
        |> Enum.sort()
        |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{inspect(value)}" end)

      [Map.get(event, "event_at"), Map.get(event, "event_type"), details]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
    end)
    |> Enum.join("\n")
  end

  @spec trace_id(String.t(), String.t()) :: String.t()
  def trace_id(issue_iid, run_id) when is_binary(issue_iid) and is_binary(run_id) do
    :crypto.hash(:sha256, "#{issue_iid}:#{run_id}")
    |> Base.url_encode64(padding: false)
    |> String.slice(0, 20)
  end

  defp merge_correlation(issue_iid, attrs) do
    issue_context = context(issue_iid)
    attrs = stringify_keys(attrs)

    issue_context
    |> Map.merge(attrs)
    |> maybe_put("issue_iid", issue_iid)
  end

  defp event_details(attrs) do
    attrs
    |> Map.drop(["trace_id", "run_id", "issue_iid", "run_fingerprint"])
    |> sanitize_map()
  end

  defp sanitize_map(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key_string = to_string(key)

      if redacted_key?(key_string) do
        acc
      else
        Map.put(acc, key_string, sanitize_value(value))
      end
    end)
  end

  defp sanitize_value(%{} = value), do: sanitize_map(value)
  defp sanitize_value(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)
  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_value(value) when is_integer(value) or is_boolean(value), do: value
  defp sanitize_value(nil), do: nil

  defp sanitize_value(value) when is_binary(value) do
    value
    |> String.slice(0, 500)
    |> redact_known_patterns()
  end

  defp sanitize_value(value) do
    value
    |> inspect(limit: 20, printable_limit: 500)
    |> String.slice(0, 500)
    |> redact_known_patterns()
  end

  defp redact_known_patterns(value) when is_binary(value) do
    value
    |> then(&Regex.replace(~r/glpat-[[:alnum:]_\-]+/u, &1, @redacted))
    |> then(&Regex.replace(~r/GITLAB_WEBHOOK_SECRET=[^\s]+/u, &1, @redacted))
    |> then(&Regex.replace(~r/GITLAB_API_TOKEN=[^\s]+/u, &1, @redacted))
  end

  defp redacted_key?(key) when is_binary(key) do
    downcased = String.downcase(key)
    Enum.any?(@redacted_key_fragments, &String.contains?(downcased, &1))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp get_issue_iid(attrs) do
    case Map.get(attrs, :issue_iid) || Map.get(attrs, "issue_iid") do
      issue_iid when is_binary(issue_iid) -> issue_iid
      issue_iid when is_integer(issue_iid) -> Integer.to_string(issue_iid)
      _ -> nil
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
