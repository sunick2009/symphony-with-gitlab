defmodule SymphonyElixirWeb.GitLabWebhookController do
  @moduledoc """
  Receives GitLab project webhooks for the GitLab adapter.
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.GitLab.Webhook

  @spec receive_webhook(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def receive_webhook(conn, params) do
    headers = Map.new(conn.req_headers)

    case Webhook.handle(headers, params) do
      {:ok, status} ->
        json(conn, %{status: status})

      {:error, reason} ->
        conn
        |> put_status(status_for_error(reason))
        |> json(%{error: %{code: format_error(reason)}})
    end
  end

  defp status_for_error(:invalid_gitlab_webhook_token), do: 401
  defp status_for_error(:missing_gitlab_webhook_token), do: 401
  defp status_for_error(:missing_gitlab_webhook_secret), do: 503
  defp status_for_error(_reason), do: 422

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
