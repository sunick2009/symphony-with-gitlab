defmodule SymphonyElixir.GitLab.Command do
  @moduledoc """
  Parser for GitLab issue comment bot commands.
  """

  @valid_commands ~w(run status retry cancel)

  @type t :: %__MODULE__{name: String.t(), raw: String.t()}

  defstruct [:name, :raw]

  @spec parse(String.t()) :: {:ok, [t()]} | :ignore | {:error, {:unknown_command, String.t()}}
  def parse(body) when is_binary(body) do
    body
    |> String.split(~r/\R/, trim: false)
    |> Enum.flat_map(&command_from_line/1)
    |> case do
      [] -> :ignore
      commands -> validate_commands(commands)
    end
  end

  def parse(_body), do: :ignore

  defp command_from_line("/soc" <> rest = raw) when rest == "" or binary_part(rest, 0, 1) in [" ", "\t"] do
    command_from_prefix(rest, raw)
  end

  defp command_from_line("/agent" <> rest = raw) when rest == "" or binary_part(rest, 0, 1) in [" ", "\t"] do
    command_from_prefix(rest, raw)
  end

  defp command_from_line(_line), do: []

  defp command_from_prefix(rest, raw) do
    rest
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2, trim: true)
    |> case do
      [name | _] -> [%__MODULE__{name: String.downcase(name), raw: raw}]
      [] -> [%__MODULE__{name: "", raw: raw}]
    end
  end

  defp validate_commands(commands) do
    case Enum.find(commands, &(&1.name not in @valid_commands)) do
      nil -> {:ok, commands}
      %__MODULE__{name: name} -> {:error, {:unknown_command, name}}
    end
  end
end
