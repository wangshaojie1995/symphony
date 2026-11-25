defmodule SymphonyElixir.Yunxiao.AgentTool do
  @moduledoc """
  Project-scoped Projex operations for Codex app-server sessions.
  """

  alias SymphonyElixir.Yunxiao.Client

  @tool "yunxiao_api"

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @tool,
        "description" => "Read a Yunxiao work item or its workflow, change its status, or add a Markdown comment.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["operation", "id"],
          "properties" => %{
            "operation" => %{
              "type" => "string",
              "enum" => ["get_workitem", "get_workflow", "update_status", "add_comment"]
            },
            "id" => %{"type" => "string", "description" => "Internal Projex work-item ID."},
            "status_id" => %{"type" => "string", "description" => "Required for update_status."},
            "content" => %{"type" => "string", "description" => "Markdown content required for add_comment."}
          }
        }
      }
    ]
  end

  @spec execute(String.t(), term(), keyword()) :: map()
  def execute(@tool, %{"id" => id} = args, opts) do
    with {:ok, method, suffix, body} <- operation(args),
         {:ok, tracker} <- Keyword.fetch(opts, :tracker_settings),
         {:ok, response} <- Client.workitem_request(tracker, method, id, suffix, body) do
      response(true, %{"status" => response.status, "body" => response.body})
    else
      :error -> response(false, %{"error" => "Missing Yunxiao tracker settings."})
      {:error, reason} -> response(false, %{"error" => inspect(reason)})
    end
  end

  def execute(_tool, _args, _opts) do
    response(false, %{"error" => "yunxiao_api requires an operation and a work-item ID."})
  end

  defp operation(%{"operation" => "get_workitem"}), do: {:ok, :get, "", nil}
  defp operation(%{"operation" => "get_workflow"}), do: {:ok, :get, "/workflow", nil}

  defp operation(%{"operation" => "update_status", "status_id" => id}) when is_binary(id) and byte_size(id) > 0 do
    {:ok, :put, "", %{"status" => id}}
  end

  defp operation(%{"operation" => "add_comment", "content" => content}) when is_binary(content) and byte_size(content) > 0 do
    {:ok, :post, "/comments", %{"content" => content, "formatType" => "MARKDOWN"}}
  end

  defp operation(_args), do: {:error, :invalid_yunxiao_tool_arguments}

  defp response(success, payload) do
    output = Jason.encode!(payload)
    %{"success" => success, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end
end
