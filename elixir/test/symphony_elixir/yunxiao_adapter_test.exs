defmodule SymphonyElixir.Yunxiao.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Yunxiao.Adapter

  @central_path "/oapi/v1/projex/organizations/org-1/workitems"
  @token_env "SYMPHONY_TEST_YUNXIAO_TOKEN"

  setup do
    previous_options = Req.default_options()
    previous_token = System.get_env(@token_env)
    System.put_env(@token_env, "test-token")
    Req.default_options(Keyword.put(previous_options, :plug, {Req.Test, __MODULE__}))

    on_exit(fn ->
      Req.default_options(previous_options)
      restore_env(@token_env, previous_token)
    end)

    load_workflow!("organization_id: org-1")
  end

  test "polls Projex by project and status ID and follows pagination headers" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == @central_path <> ":search"
      assert Plug.Conn.get_req_header(conn, "x-yunxiao-token") == ["test-token"]

      assert %{"spaceId" => "project-1", "category" => "Req,Bug,Task", "page" => 1, "conditions" => conditions} =
               json_body(conn)

      assert %{"conditionGroups" => [[%{"fieldIdentifier" => "status", "value" => ["100005"]}]]} =
               Jason.decode!(conditions)

      conn
      |> Plug.Conn.put_resp_header("x-next-page", "2")
      |> Req.Test.json([
        workitem("item-1"),
        workitem("item-2", %{"status" => %{"id" => "100015"}}),
        workitem("item-3", %{"space" => %{"id" => "other-project"}})
      ])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert %{"page" => 2} = json_body(conn)

      conn
      |> Plug.Conn.put_resp_header("x-total-pages", "2")
      |> Req.Test.json([workitem("item-1"), workitem("item-4", %{"logicalStatus" => "archived"})])
    end)

    assert :ok = Config.validate!()

    assert {:ok, [%Issue{id: "item-1"} = issue, %Issue{id: "item-4", dispatchable: false}]} =
             Tracker.fetch_issues_by_states(["100005"])

    assert issue.identifier == "DEMO-item-1"
    assert issue.title == "Repair build"
    assert issue.description == "Steps to reproduce"
    assert issue.labels == ["symphony"]
    assert issue.assignee_id == "assignee-1"
    assert issue.state == "100005"
    assert issue.created_at == ~U[2025-01-01 00:00:00Z]
    assert Issue.routable?(issue, ["symphony"])
    Req.Test.verify!()
  end

  test "refreshes terminal work items by ID and omits deleted or moved items" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == @central_path <> "/item-1"
      Req.Test.json(conn, workitem("item-1", %{"status" => %{"id" => "100015"}}))
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == @central_path <> "/deleted"
      Plug.Conn.send_resp(conn, 404, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == @central_path <> "/moved"
      Req.Test.json(conn, workitem("moved", %{"space" => %{"id" => "other-project"}}))
    end)

    assert {:ok, [%Issue{id: "item-1", state: "100015"}]} =
             Tracker.fetch_issues_by_ids(["item-1", "deleted", "moved", "item-1"])

    Req.Test.verify!()
  end

  test "malformed refresh payload propagates an error instead of dropping active work" do
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"id" => "item-1"}))

    assert {:error, :invalid_yunxiao_payload} = Tracker.fetch_issues_by_ids(["item-1"])
    Req.Test.verify!()
  end

  test "uses the Region API path and sends a project-scoped status change using the bound tool" do
    load_workflow!(~s(api_url: "https://region.example.com"))
    assert :ok = Config.validate!()
    binding = Tracker.bind_agent_tools()
    assert [%{"name" => "yunxiao_api"}] = binding.tool_specs
    assert @token_env in binding.secret_environment_names
    assert "ALIBABA_CLOUD_YUNXIAO_ACCESS_TOKEN" in binding.secret_environment_names

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.host == "region.example.com"
      assert conn.request_path == "/oapi/v1/projex/workitems/item-1"
      Req.Test.json(conn, workitem("item-1"))
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/oapi/v1/projex/workitems/item-1"
      assert json_body(conn) == %{"status" => "100015"}
      Req.Test.json(conn, %{})
    end)

    assert %{"success" => true} =
             Tracker.execute_bound_agent_tool(binding, "yunxiao_api", %{
               "operation" => "update_status",
               "id" => "item-1",
               "status_id" => "100015"
             })

    Req.Test.verify!()
  end

  test "rejects writes outside the configured project and validates endpoint and configuration" do
    tracker = Config.settings!().tracker

    assert {:error, :invalid_yunxiao_active_states} =
             Adapter.validate_config(%{tracker | active_states: nil})

    assert {:error, :invalid_yunxiao_organization_id} =
             Adapter.validate_config(%{tracker | provider: Map.delete(tracker.provider, "organization_id")})

    assert {:error, :invalid_yunxiao_api_url} =
             Adapter.validate_config(%{tracker | provider: Map.put(tracker.provider, "api_url", "http://invalid.example")})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, workitem("moved", %{"space" => %{"id" => "other-project"}}))
    end)

    assert %{"success" => false} =
             Tracker.execute_bound_agent_tool(Tracker.bind_agent_tools(), "yunxiao_api", %{
               "operation" => "add_comment",
               "id" => "moved",
               "content" => "Test result"
             })

    Req.Test.verify!()
  end

  test "reads work-item details and workflow and posts Markdown comments" do
    binding = Tracker.bind_agent_tools()

    expect_workitem_read()
    assert %{"success" => true, "output" => output} = tool(binding, "get_workitem")
    assert %{"body" => %{"id" => "item-1"}} = Jason.decode!(output)

    expect_workitem_read()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == @central_path <> "/item-1/workflow"
      Req.Test.json(conn, %{"statuses" => []})
    end)

    assert %{"success" => true, "output" => output} = tool(binding, "get_workflow")
    assert %{"body" => %{"statuses" => []}} = Jason.decode!(output)

    expect_workitem_read()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == @central_path <> "/item-1/comments"
      assert json_body(conn) == %{"content" => "Tests passed", "formatType" => "MARKDOWN"}
      Req.Test.json(conn, %{"id" => "comment-1"})
    end)

    assert %{"success" => true, "output" => output} = tool(binding, "add_comment", %{"content" => "Tests passed"})
    assert %{"body" => %{"id" => "comment-1"}} = Jason.decode!(output)
    Req.Test.verify!()
  end

  defp expect_workitem_read do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == @central_path <> "/item-1"
      Req.Test.json(conn, workitem("item-1"))
    end)
  end

  test "rejects tool calls with malformed arguments or without bound settings" do
    assert %{"success" => false} = Adapter.execute_agent_tool("yunxiao_api", %{}, [])
    assert %{"success" => false} = Adapter.execute_agent_tool("yunxiao_api", %{"id" => "item-1", "operation" => "get_workitem"}, [])
    assert %{"success" => false} = tool(Tracker.bind_agent_tools(), "update_status")
  end

  defp tool(binding, operation, args \\ %{}) do
    args = Map.merge(%{"id" => "item-1", "operation" => operation}, args)
    Tracker.execute_bound_agent_tool(binding, "yunxiao_api", args)
  end

  defp load_workflow!(provider_line) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: yunxiao
      provider:
        #{provider_line}
        project_id: project-1
        api_key: $#{@token_env}
      active_states: ["100005"]
      terminal_states: ["100015"]
    polling:
      interval_ms: 600000
    ---
    Handle this work item.
    """)

    WorkflowStore.force_reload()
    :ok
  end

  defp workitem(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "serialNumber" => "DEMO-#{id}",
        "subject" => "Repair build",
        "description" => "Steps to reproduce",
        "status" => %{"id" => "100005", "displayName" => "待处理"},
        "space" => %{"id" => "project-1"},
        "assignedTo" => %{"id" => "assignee-1"},
        "labels" => [%{"name" => " Symphony "}],
        "gmtCreate" => "2025-01-01T00:00:00Z"
      },
      overrides
    )
  end

  defp json_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end
end
