defmodule SymphonyElixir.Yunxiao.Adapter do
  @moduledoc """
  Alibaba Cloud Yunxiao Projex work-item tracker.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Yunxiao.{AgentTool, Client}

  @impl true
  def validate_config(tracker), do: Client.validate_settings(tracker)

  @impl true
  def fetch_issues_by_states(states), do: Client.fetch_issues_by_states(states)

  @impl true
  def fetch_issues_by_ids(ids), do: Client.fetch_issues_by_ids(ids)

  @impl true
  def agent_tool_specs, do: AgentTool.tool_specs()

  @impl true
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)

  @impl true
  def secret_environment_names(tracker), do: Client.secret_environment_names(tracker)
end
