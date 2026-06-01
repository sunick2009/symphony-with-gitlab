defmodule SymphonyElixir.GitLab.Webhook do
  @moduledoc """
  GitLab webhook handling for adapter-controlled issue commands.
  """

  require Logger

  alias SymphonyElixir.{Config, GitLab.Adapter, GitLab.Audit, GitLab.Command, GitLab.StateStore}

  @not_implemented_commands ~w(status retry cancel)
  @run_blocking_labels [
    "soc::queued",
    "soc::claimed",
    "soc::running",
    "soc::waiting-input",
    "soc::human-review",
    "soc::failed",
    "soc::done"
  ]

  @spec handle(map(), map()) :: {:ok, atom()} | {:error, term()}
  def handle(headers, payload) when is_map(headers) and is_map(payload) do
    Audit.emit("webhook.received", %{
      source: "gitlab",
      issue_iid: payload |> issue_iid() |> issue_iid_for_audit(),
      event_type: header(headers, "x-gitlab-event")
    })

    with :ok <- validate_secret(headers),
         {:ok, event_key} <- event_key(headers, payload),
         :ok <- begin_event(event_key, headers, payload) do
      result = dispatch_event(header(headers, "x-gitlab-event"), payload, event_key)
      :ok = finish_event(event_key, result)
      result
    else
      {:ok, :duplicate} ->
        Audit.emit("duplicate.suppressed", %{
          source: "gitlab",
          issue_iid: payload |> issue_iid() |> issue_iid_for_audit(),
          reason: "webhook_replay"
        })

        {:ok, :duplicate}

      {:error, reason} ->
        Audit.emit(
          "error.recorded",
          %{
            source: "gitlab",
            issue_iid: payload |> issue_iid() |> issue_iid_for_audit(),
            reason: inspect(reason)
          },
          level: :warning
        )

        {:error, reason}
    end
  end

  @spec reset_idempotency_for_test() :: :ok
  def reset_idempotency_for_test do
    StateStore.reset_for_test()
  end

  defp dispatch_event("Note Hook", payload, event_key), do: handle_note_hook(payload, event_key)
  defp dispatch_event("Issue Hook", _payload, _event_key), do: {:ok, :ignored}
  defp dispatch_event(_event, _payload, _event_key), do: {:ok, :ignored}

  defp handle_note_hook(payload, event_key) do
    if issue_note?(payload) do
      payload
      |> note_body()
      |> Command.parse()
      |> handle_commands(payload, event_key)
    else
      {:ok, :ignored}
    end
  end

  defp handle_commands(:ignore, _payload, _event_key), do: {:ok, :ignored}

  defp handle_commands({:error, {:unknown_command, command}}, payload, event_key) do
    Audit.emit("command.parsed", %{
      issue_iid: payload |> issue_iid() |> issue_iid_for_audit(),
      command: command,
      result: "unsupported",
      run_id: event_key
    })

    with {:ok, issue_iid} <- issue_iid(payload) do
      Adapter.create_comment_once(issue_iid, "webhook:#{event_key}:unsupported", "Unsupported Symphony command: `/soc #{command}`.")
    end
    |> normalize_writeback_result(:handled)
  end

  defp handle_commands({:ok, commands}, payload, event_key) do
    first_command = commands |> List.first() |> Map.get(:name)

    Audit.emit("command.parsed", %{
      issue_iid: payload |> issue_iid() |> issue_iid_for_audit(),
      command: first_command,
      result: "accepted",
      run_id: event_key
    })

    commands
    |> List.first()
    |> handle_command(payload, event_key)
  end

  defp handle_command(%Command{name: "run"}, payload, event_key), do: handle_run_command(payload, event_key)

  defp handle_command(%Command{name: command}, payload, event_key) when command in @not_implemented_commands do
    with {:ok, issue_iid} <- issue_iid(payload) do
      Adapter.create_comment_once(
        issue_iid,
        "webhook:#{event_key}:not-implemented",
        "The `/soc #{command}` command is recognized but is not implemented yet."
      )
    end
    |> normalize_writeback_result(:handled)
  end

  defp handle_command(_command, _payload, _event_key), do: {:ok, :ignored}

  defp handle_run_command(payload, event_key) do
    with {:ok, issue_iid} <- issue_iid(payload),
         {:ok, _context} <- Audit.start_trace(issue_iid, event_key, %{source: "gitlab", event_key: event_key}),
         :ok <- ensure_issue_open(payload, issue_iid, event_key),
         :ok <- ensure_issue_not_already_in_lifecycle(payload, issue_iid, event_key),
         :ok <- Adapter.transition_issue_labels(issue_iid, "soc::queued"),
         :ok <-
           Adapter.create_comment_once(
             issue_iid,
             "webhook:#{event_key}:accepted",
             "Symphony accepted `/soc run` and queued this issue for an agent run."
           ) do
      Audit.emit("issue.queued", %{issue_iid: issue_iid, run_id: event_key, source: "gitlab"})
      {:ok, :handled}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_issue_open(payload, issue_iid, event_key) do
    if issue_state(payload) == "closed" do
      Adapter.create_comment_once(issue_iid, "webhook:#{event_key}:closed", "Symphony cannot run on a closed GitLab issue.")
      Audit.emit("duplicate.suppressed", %{issue_iid: issue_iid, run_id: event_key, reason: "closed_issue"})
      {:error, :closed_issue}
    else
      :ok
    end
  end

  defp ensure_issue_not_already_in_lifecycle(payload, issue_iid, event_key) do
    labels = issue_labels(payload)

    if Enum.any?(labels, &(normalize_label(&1) in @run_blocking_labels)) do
      Adapter.create_comment_once(
        issue_iid,
        "webhook:#{event_key}:already-in-lifecycle",
        "Symphony cannot queue this issue because it is already in a Symphony lifecycle state."
      )

      Audit.emit("duplicate.suppressed", %{issue_iid: issue_iid, run_id: event_key, reason: "issue_already_in_lifecycle"})
      {:error, :issue_already_in_lifecycle}
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

  defp begin_event(event_key, headers, payload) do
    StateStore.begin_webhook_event(event_key, %{
      event_type: header(headers, "x-gitlab-event"),
      issue_iid: payload |> issue_iid() |> issue_iid_for_audit(),
      source: "gitlab"
    })
  end

  defp finish_event(event_key, {:ok, status}) when is_atom(status) do
    StateStore.finish_webhook_event(event_key, status, status)
  end

  defp finish_event(event_key, {:error, reason}) do
    StateStore.finish_webhook_event(event_key, :failed, reason)
  end

  defp event_key(headers, payload) do
    cond do
      note_id = issue_note_id(payload) ->
        {:ok, "note:" <> to_string(note_id)}

      event_uuid = header(headers, "x-gitlab-event-uuid") ->
        {:ok, "event:" <> event_uuid}

      issue_id = get_in(payload, ["object_attributes", "id"]) ->
        {:ok, "object:" <> to_string(issue_id)}

      true ->
        {:error, :missing_gitlab_event_id}
    end
  end

  defp issue_note_id(payload) do
    if issue_note?(payload), do: get_in(payload, ["object_attributes", "id"])
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

  defp issue_iid_for_audit({:ok, issue_iid}), do: issue_iid
  defp issue_iid_for_audit({:error, _reason}), do: nil

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
