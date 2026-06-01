defmodule Mix.Tasks.Gitlab.Timeline do
  @moduledoc """
  Print a sanitized GitLab audit timeline for one issue IID or trace ID.
  """

  use Mix.Task

  alias SymphonyElixir.GitLab.Audit

  @shortdoc "Print a GitLab audit timeline"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [issue: :string, trace: :string]
      )

    issue_iid = Keyword.get(opts, :issue)
    trace_id = Keyword.get(opts, :trace)

    if is_nil(issue_iid) and is_nil(trace_id) do
      Mix.raise("pass --issue <iid> or --trace <trace_id>")
    end

    events = Audit.list_events(issue_iid: issue_iid, trace_id: trace_id)

    if events == [] do
      Mix.shell().info("No matching GitLab audit events.")
    else
      Mix.shell().info(Audit.format_timeline(events))
    end
  end
end
