defmodule Cybernetic.MCP.CoreTest do
  use ExUnit.Case, async: false
  alias Cybernetic.MCP.Core
  alias Cybernetic.Core.MCP.Hermes.Registry

  describe "MCP Core" do
    setup do
      # Start MCP Core and Registry
      {:ok, _registry} = Registry.start_link()
      {:ok, pid} = Core.start_link()
      
      # Wait for initial discovery
      Process.sleep(200)
      
      {:ok, mcp: pid}
    end

    test "discovers and registers tools on startup", %{mcp: _mcp} do
      # List available tools
      tools = Core.list_tools()
      
      assert length(tools) > 0
      assert Enum.any?(tools, fn t -> t.name == "search" end)
      assert Enum.any?(tools, fn t -> t.name == "calculate" end)
      assert Enum.any?(tools, fn t -> t.name == "analyze" end)
      
      # Verify tools are registered in registry
      registered = Registry.list_tools()
      assert length(registered) > 0
    end

    test "calls a tool with parameters", %{mcp: _mcp} do
      # Call the search tool
      params = %{query: "Elixir VSM cybernetics", limit: 10}
      {:ok, result} = Core.call_tool("search", params)
      
      assert result.tool == "search"
      assert result.params == params
      assert result.result =~ "Mock result"
      assert is_struct(result.timestamp, DateTime)
    end

    test "handles tool call with timeout", %{mcp: _mcp} do
      # Call with custom timeout
      params = %{complex_data: "test"}
      {:ok, result} = Core.call_tool("analyze", params, 5000)
      
      assert result.tool == "analyze"
      assert result.params == params
    end

    test "sends prompts with context", %{mcp: _mcp} do
      prompt = "Explain the Viable System Model"
      context = %{
        system: "VSM",
        focus: "System 2 coordination"
      }
      
      {:ok, response} = Core.send_prompt(prompt, context)
      
      assert response.prompt == prompt
      assert response.context == context
      assert response.response =~ "Mock response"
    end

    test "sends prompts without context", %{mcp: _mcp} do
      prompt = "What is recursion?"
      
      {:ok, response} = Core.send_prompt(prompt)
      
      assert response.prompt == prompt
      assert response.context == %{}
      assert response.response =~ "Mock response"
    end

    test "lists all available tools", %{mcp: _mcp} do
      tools = Core.list_tools()
      
      assert is_list(tools)
      assert length(tools) == 3
      
      tool_names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert tool_names == ["analyze", "calculate", "search"]
      
      # Each tool should have name and description
      for tool <- tools do
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
        assert is_binary(tool.name)
        assert is_binary(tool.description)
      end
    end

    test "handles concurrent tool calls", %{mcp: _mcp} do
      # Launch multiple concurrent tool calls
      tasks = for i <- 1..10 do
        Task.async(fn ->
          tool = Enum.random(["search", "calculate", "analyze"])
          params = %{id: i, data: "test#{i}"}
          Core.call_tool(tool, params)
        end)
      end
      
      # Collect all results
      results = Enum.map(tasks, &Task.await/1)
      
      # All should succeed
      assert length(results) == 10
      assert Enum.all?(results, fn r -> 
        match?({:ok, _}, r)
      end)
      
      # Each should have unique params
      param_ids = results 
        |> Enum.map(fn {:ok, r} -> r.params.id end)
        |> Enum.sort()
      
      assert param_ids == Enum.to_list(1..10)
    end

    test "tool discovery happens automatically", %{mcp: _mcp} do
      # Get initial tool count
      initial_tools = Core.list_tools()
      initial_count = length(initial_tools)
      
      # Tools should already be discovered from setup
      assert initial_count > 0
      
      # Verify specific tools exist
      tool_names = Enum.map(initial_tools, & &1.name)
      assert "search" in tool_names
      assert "calculate" in tool_names
      assert "analyze" in tool_names
    end
  end
end