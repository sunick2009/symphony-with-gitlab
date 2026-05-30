defmodule SymphonyElixir.GitLab.Webhook do
  @moduledoc """
  GitLab webhook handling for adapter-controlled issue commands.
  """

  require Logger

  alias SymphonyElixir.{Config, GitLab.Adapter, GitLab.Command}

  @idempotency_table :symphony_gitlab_webhook_events
  @not_implemented_commands ~w(status retry cancel)

  @spec handle(map(), map()) :: {:ok, atom()} | {:error, term()}
  def handle(headers, payload) when is_map(headers) and is_map(payload) do
    with :ok <- validate_secret(headers),
         {:ok, event_key} <- event_key(headers, payload),
         :ok <- record_event(event_key) do
      dispatch_event(header(headers, "x-gitlab-event"), payload)
    end
  end

  @spec reset_idempotency_for_test() :: :ok
  def reset_idempotency_for_test do
    ensure_table()
    :ets.delete_all_objects(@idempotency_table)
    :ok
  end

  defp dispatch_event("Note Hook", payload), do: handle_note_hook(payload)
  defp dispatch_event("Issue Hook", _payload), do: {:ok, :ignored}
  defp dispatch_event(_event, _payload), do: {:ok, :ignored}

  defp handle_note_hook(payload) do
    if issue_note?(payload) do
      payload
      |> note_body()
      |> Command.parse()
      |> handle_commands(payload)
    else
      {:ok, :ignored}
    end
  end

  defp handle_commands(:ignore, _payload), do: {:ok, :ignored}

  defp handle_commands({:error, {:unknown_command, command}}, payload) do
    with {:ok, issue_iid} <- issue_iid(payload) do
      Adapter.create_comment(issue_iid, "Unsupported Symphony command: `/soc #{command}`.")
    end
    |> normalize_writeback_result(:handled)
  end

  defp handle_commands({:ok, commands}, payload) do
    commands
    |> List.first()
    |> handle_command(payload)
  end

  defp handle_command(%Command{name: "run"}, payload), do: handle_run_command(payload)

  defp handle_command(%Command{name: command}, payload) when command in @not_implemented_commands do
    with {:ok, issue_iid} <- issue_iid(payload) do
      Adapter.create_comment(issue_iid, "The `/soc #{command}` command is recognized but is not implemented yet.")
    end
    |> normalize_writeback_result(:handled)
  end

  defp handle_command(_command, _payload), do: {:ok, :ignored}

  defp handle_run_command(payload) do
    with {:ok, issue_iid} <- issue_iid(payload),
         :ok <- ensure_issue_open(payload, issue_iid),
         :ok <- ensure_issue_not_already_running(payload, issue_iid),
         :ok <- Adapter.transition_issue_labels(issue_iid, "soc::queued"),
         :ok <- Adapter.create_comment(issue_iid, "Symphony accepted `/soc run` and queued this issue for an agent run.") do
      {:ok, :handled}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_issue_open(payload, issue_iid) do
    if issue_state(payload) == "closed" do
      Adapter.create_comment(issue_iid, "Symphony cannot run on a closed GitLab issue.")
      {:error, :closed_issue}
    else
      :ok
    end
  end

  defp ensure_issue_not_already_running(payload, issue_iid) do
    labels = issue_labels(payload)

    if Enum.any?(labels, &(normalize_label(&1) in ["soc::claimed", "soc::running"])) do
      Adapter.create_comment(issue_iid, "Symphony cannot queue this issue because it is already claimed or running.")
      {:error, :issue_already_running}
    else
      :ok
    end
  end

  defp validate_secret(headers) do
    expected = Config.settings!().tracker.webhook_secret
    received = header(headers, "x-gitlab-token")

    cond do
      not is_binary(expected) ->
        {:error, :missing_gitlab_webhook_secret}

      not is_binary(received) ->
        {:error, :missing_gitlab_webhook_token}

      secure_compare(expected, received) ->
        :ok

      true ->
        {:error, :invalid_gitlab_webhook_token}
    end
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp record_event(event_key) do
    ensure_table()

    if :ets.insert_new(@idempotency_table, {event_key, System.system_time(:second)}) do
      :ok
    else
      {:ok, :duplicate}
    end
  end

  defp ensure_table do
    case :ets.whereis(@idempotency_table) do
      :undefined ->
        try do
          :ets.new(@idempotency_table, [:named_table, :public, :set])
        rescue
          ArgumentError -> @idempotency_table
        end

      _tid ->
        @idempotency_table
    end
  end

  defp event_key(headers, payload) do
    cond do
      event_uuid = header(headers, "x-gitlab-event-uuid") ->
        {:ok, "event:" <> event_uuid}

      note_id = get_in(payload, ["object_attributes", "id"]) ->
        {:ok, "note:" <> to_string(note_id)}

      issue_id = get_in(payload, ["object_attributes", "id"]) ->
        {:ok, "issue:" <> to_string(issue_id)}

      true ->
        {:error, :missing_gitlab_event_id}
    end
  end

  defp issue_note?(payload) do
    get_in(payload, ["object_attributes", "noteable_type"]) == "Issue" or
      get_in(payload, ["object_attributes", "type"]) == "Issue"
  end

  defp note_body(payload), do: get_in(payload, ["object_attributes", "note"])

  defp issue_iid(payload) do
    [
      get_in(payload, ["issue", "iid"]),
      get_in(payload, ["object_attributes", "noteable_iid"]),
      get_in(payload, ["object_attributes", "iid"])
    ]
    |> Enum.find_value(&normalize_iid/1)
    |> case do
      nil -> {:error, :missing_gitlab_issue_iid}
      iid -> {:ok, iid}
    end
  end

  defp normalize_iid(iid) when is_integer(iid), do: Integer.to_string(iid)

  defp normalize_iid(iid) when is_binary(iid) do
    trimmed = String.trim(iid)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_iid(_iid), do: nil

  defp issue_state(payload) do
    payload
    |> get_in(["issue", "state"])
    |> normalize_label()
  end

  defp issue_labels(payload) do
    case get_in(payload, ["issue", "labels"]) do
      labels when is_list(labels) -> Enum.flat_map(labels, &label_name/1)
      _ -> []
    end
  end

  defp label_name(label) when is_binary(label), do: [label]
  defp label_name(%{"title" => title}) when is_binary(title), do: [title]
  defp label_name(%{"name" => name}) when is_binary(name), do: [name]
  defp label_name(_label), do: []

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(_label), do: ""

  defp normalize_writeback_result(:ok, status), do: {:ok, status}
  defp normalize_writeback_result({:error, reason}, _status), do: {:error, reason}

  defp header(headers, wanted) do
    normalized_wanted = String.downcase(wanted)

    Enum.find_value(headers, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == normalized_wanted, do: value

      {key, [value | _]} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == normalized_wanted, do: value

      _ ->
        nil
    end)
  end
end
