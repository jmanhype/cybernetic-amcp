defmodule Cybernetic.MCP.HermesClientTest do
  use ExUnit.Case, async: true
  alias Cybernetic.MCP.HermesClient

  describe "Plugin behavior" do
    test "implements Plugin behavior correctly" do
      metadata = HermesClient.metadata()
      assert %{name: "hermes_mcp", version: "0.1.0"} = metadata
    end

    test "process/2 handles tool calls successfully" do
      # Mock successful tool call
      input = %{tool: "test_tool", params: %{data: "test"}}
      initial_state = %{cfg: [], tools: %{}, connected: false}
      
      result = HermesClient.process(input, initial_state)
      
      # Should return success with mock result
      assert {:ok, %{tool: "test_tool", result: "Mock result for test_tool"}, ^initial_state} = result
    end

    test "process/2 handles exceptions gracefully" do
      # Test with invalid input structure to trigger exception
      input = %{invalid: "structure"}
      initial_state = %{cfg: [], tools: %{}, connected: false}
      
      result = HermesClient.process(input, initial_state)
      
      # Should catch exceptions and return structured error
      assert {:error, %{error: :client_error}, ^initial_state} = result
    end

    test "handle_event/2 processes events correctly" do
      {:ok, pid} = HermesClient.start_link([])
      initial_state = %{cfg: [], tools: %{}, connected: false}
      
      result = HermesClient.handle_event(%{type: "test_event"}, initial_state)
      
      assert {:ok, ^initial_state} = result
      GenServer.stop(pid)
    end
  end

  describe "GenServer initialization" do
    test "start_link/1 starts the GenServer" do
      {:ok, pid} = HermesClient.start_link([])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "init/1 sets up initial state correctly" do
      cfg = [timeout: 5000]
      {:ok, state} = HermesClient.init(cfg)
      
      expected_state = %{
        cfg: cfg,
        tools: %{},
        connected: false
      }
      
      assert state == expected_state
    end
  end

  describe "health_check/0" do
    test "returns healthy status with tool count" do
      result = HermesClient.health_check()
      
      # Should return success with tool count
      assert {:ok, %{status: :healthy, tools_count: 3}} = result
    end
  end

  describe "get_available_tools/0" do
    test "returns mock tools for testing" do
      result = HermesClient.get_available_tools()
      
      # Should return success with mock tools
      assert {:ok, tools} = result
      assert length(tools) == 3
      
      # Verify tool structure
      first_tool = List.first(tools)
      assert %{name: "search", description: _, input_schema: _} = first_tool
    end
  end

  describe "execute_tool/3" do
    test "executes tools successfully" do
      result = HermesClient.execute_tool("test_tool", %{query: "test"}, [])
      
      # Should return success
      assert {:ok, %{result: "Mock result for test_tool", success: true}} = result
    end

    test "handles error tools" do
      result = HermesClient.execute_tool("error_tool", %{}, [])
      
      # Should return error for error_tool
      assert {:error, %{type: :tool_error, message: "Simulated tool error"}} = result
    end

    test "accepts timeout and progress callback options" do
      opts = [timeout: 10_000, progress_callback: fn _ -> :ok end]
      result = HermesClient.execute_tool("test_tool", %{}, opts)
      
      # Should process options and return success
      assert {:ok, %{result: "Mock result for test_tool"}} = result
    end

    test "uses default timeout when not specified" do
      result = HermesClient.execute_tool("test_tool", %{})
      
      # Should work with default timeout
      assert {:ok, %{result: "Mock result for test_tool"}} = result
    end
  end

  describe "Hermes.Client integration" do
    test "implements Hermes.Client use macro correctly" do
      # Verify the module has the Hermes.Client behavior
      behaviours = HermesClient.__info__(:attributes)
                  |> Enum.filter(fn {key, _} -> key == :behaviour end)
                  |> Enum.flat_map(fn {_, behaviours} -> behaviours end)
      
      # Should include Cybernetic.Plugin behavior
      assert Cybernetic.Plugin in behaviours
    end

    test "module defines expected Hermes client configuration" do
      # Test that the module is properly configured
      # The actual Hermes.Client macros should define proper callbacks
      assert function_exported?(HermesClient, :start_link, 1)
      assert function_exported?(HermesClient, :init, 1)
      assert function_exported?(HermesClient, :metadata, 0)
    end
  end

  describe "error scenarios" do
    test "handles network timeouts" do
      # Test timeout scenario
      result = HermesClient.execute_tool("slow_tool", %{}, [timeout: 1])
      
      # Should handle timeout gracefully
      assert {:error, %{type: :client_error}} = result
    end

    test "handles malformed responses" do
      # Test with invalid tool response format
      input = %{tool: "malformed_tool", params: %{}}
      state = %{cfg: [], tools: %{}, connected: false}
      
      result = HermesClient.process(input, state)
      
      # Should handle malformed responses
      assert {:error, %{tool: "malformed_tool"}, ^state} = result
    end
  end
end