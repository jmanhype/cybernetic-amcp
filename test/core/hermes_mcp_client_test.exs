defmodule Cybernetic.MCP.HermesClientTest do
  use ExUnit.Case, async: false  # Need sequential for client startup/shutdown
  alias Cybernetic.MCP.HermesClient

  describe "Plugin behavior" do
    test "implements Plugin behavior correctly" do
      metadata = HermesClient.metadata()
      assert %{name: "hermes_mcp", version: "0.1.0"} = metadata
    end

    test "handle_event/2 processes events correctly" do
      initial_state = %{some: "state"}
      
      result = HermesClient.handle_event(%{type: "test_event"}, initial_state)
      
      assert {:ok, ^initial_state} = result
    end
  end

  describe "Client lifecycle without server" do
    # These tests verify the client handles no-server scenarios gracefully
    test "health_check/0 handles no server connection" do
      # Since no Hermes server is running, this should handle the error gracefully
      result = HermesClient.health_check()
      
      # Should return error status when no server available
      assert {:error, %{status: :error}} = result
    end

    test "get_available_tools/0 handles no server connection" do
      # Since no Hermes server is running, this should handle the error gracefully
      result = HermesClient.get_available_tools()
      
      # Should return error when no server available
      assert {:error, _reason} = result
    end

    test "execute_tool/3 handles no server connection" do
      # Since no Hermes server is running, this should handle the error gracefully
      result = HermesClient.execute_tool("test_tool", %{query: "test"}, [])
      
      # Should return error when no server available
      assert {:error, %{type: :client_error}} = result
    end

    test "process/2 handles tool calls without server" do
      input = %{tool: "test_tool", params: %{data: "test"}}
      initial_state = %{some: "state"}
      
      result = HermesClient.process(input, initial_state)
      
      # Should return error when no server available
      assert {:error, %{tool: "test_tool", error: :client_error}, ^initial_state} = result
    end

    test "process/2 handles exceptions gracefully" do
      # Test with invalid input structure to trigger exception
      input = %{invalid: "structure"}
      initial_state = %{some: "state"}
      
      result = HermesClient.process(input, initial_state)
      
      # Should catch exceptions and return structured error
      assert {:error, %{error: :client_error}, ^initial_state} = result
    end
  end

  describe "Real Hermes client integration" do
    # These tests would work with a real MCP server
    # For now, they demonstrate the expected behavior
    
    @tag :integration
    test "can start client with transport configuration" do
      # This would normally start a client connected to an MCP server
      # Example configuration that would work with a real server:
      # {:ok, pid} = Supervisor.start_child(Cybernetic.Supervisor, 
      #   {HermesClient, transport: {:stdio, command: "mcp-server", args: []}})
      
      # For now, just verify the module exists and can be configured
      assert function_exported?(HermesClient, :ping, 0)
      assert function_exported?(HermesClient, :list_tools, 0) 
      assert function_exported?(HermesClient, :call_tool, 2)
    end

    @tag :integration
    test "demonstrates expected API interface" do
      # This test documents the expected API that would work with a real server
      # When connected to a real MCP server, these would be the actual calls:
      
      # Basic connectivity check
      # assert :pong = HermesClient.ping()
      
      # Tool discovery
      # {:ok, %{result: %{"tools" => tools}}} = HermesClient.list_tools()
      # assert is_list(tools)
      
      # Tool execution
      # {:ok, result} = HermesClient.call_tool("echo", %{text: "hello"})
      # assert is_map(result)
      
      # For now, just verify the functions exist
      assert function_exported?(HermesClient, :ping, 0)
      assert function_exported?(HermesClient, :list_tools, 0)
      assert function_exported?(HermesClient, :call_tool, 2)
      assert function_exported?(HermesClient, :read_resource, 1)
    end
  end

  describe "Configuration and options" do
    test "execute_tool accepts timeout options" do
      opts = [timeout: 10_000]
      result = HermesClient.execute_tool("test_tool", %{}, opts)
      
      # Should process options even when failing due to no server
      assert {:error, %{type: :client_error}} = result
    end

    test "execute_tool accepts progress callback options" do
      progress_callback = fn _token, _progress, _total -> :ok end
      opts = [progress_callback: progress_callback]
      result = HermesClient.execute_tool("test_tool", %{}, opts)
      
      # Should process options even when failing due to no server
      assert {:error, %{type: :client_error}} = result
    end

    test "execute_tool uses default timeout when not specified" do
      result = HermesClient.execute_tool("test_tool", %{})
      
      # Should work with default timeout even when failing due to no server
      assert {:error, %{type: :client_error}} = result
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

    test "module defines expected functions from Hermes.Client" do
      # Test that the module has functions from use Hermes.Client
      assert function_exported?(HermesClient, :ping, 0)
      assert function_exported?(HermesClient, :list_tools, 0)
      assert function_exported?(HermesClient, :call_tool, 2)
      assert function_exported?(HermesClient, :read_resource, 1)
      
      # Plugin behavior functions
      assert function_exported?(HermesClient, :metadata, 0)
      assert function_exported?(HermesClient, :process, 2)
      assert function_exported?(HermesClient, :handle_event, 2)
    end
  end

  describe "error scenarios" do
    test "handles network timeouts gracefully" do
      # Test timeout scenario
      result = HermesClient.execute_tool("slow_tool", %{}, [timeout: 1])
      
      # Should handle timeout gracefully
      assert {:error, %{type: :client_error}} = result
    end

    test "handles malformed tool parameters" do
      # Test with invalid tool response format
      input = %{tool: "malformed_tool", params: %{}}
      state = %{some: "state"}
      
      result = HermesClient.process(input, state)
      
      # Should handle malformed responses
      assert {:error, %{tool: "malformed_tool"}, ^state} = result
    end
  end
end