defmodule Cybernetic.Core.MCP.ResultPathTest do
  @moduledoc """
  Regression tests for the MCP result path (Issue #86, P0).

  Previously `Registry.invoke_tool/3` replied with an invocation id
  before the tool ran and discarded the result on completion, so no
  MCP response ever carried a tool's actual output.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Core.MCP.Handler
  alias Cybernetic.Core.MCP.Hermes.Registry

  setup do
    {pid, started_here?} =
      case Registry.start_link([]) do
        {:ok, pid} -> {pid, true}
        {:error, {:already_started, pid}} -> {pid, false}
      end

    :ok = Registry.await_ready(2_000)

    if started_here? do
      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)
    end

    :ok
  end

  test "invoke_tool returns the tool's actual result, not an invocation id" do
    assert {:ok, nonce} = Registry.invoke_tool("generate_nonce", %{})
    assert is_binary(nonce)
    # NonceBloom.generate_nonce/0 returns a 21-char Nanoid
    assert byte_size(nonce) == 21
    refute String.starts_with?(nonce, "inv_")

    # A second call really executes the tool again
    assert {:ok, other} = Registry.invoke_tool("generate_nonce", %{})
    assert other != nonce
  end

  test "invoke_tool still returns :not_found for unknown tools" do
    assert {:error, :not_found} = Registry.invoke_tool("no_such_tool", %{})
  end

  test "completed invocations are recorded in stats" do
    {:ok, before_stats} = Registry.get_stats()
    assert {:ok, _nonce} = Registry.invoke_tool("generate_nonce", %{})
    {:ok, after_stats} = Registry.get_stats()

    assert after_stats.success == before_stats.success + 1
    assert after_stats.total_calls == before_stats.total_calls + 1
  end

  test "handler tool_request response carries the tool result" do
    message = %{
      "type" => "tool_request",
      "tool" => "generate_nonce",
      "params" => %{},
      "id" => "req-result-1"
    }

    assert {:ok, response} = Handler.process(message)
    assert response["type"] == "tool_response"
    assert response["id"] == "req-result-1"
    assert response["status"] == "success"
    assert is_binary(response["result"])
    assert byte_size(response["result"]) == 21
  end

  test "handler tool_request for a failing tool returns an error response" do
    # vsm_query's handler is real now; an unknown system makes the
    # tool itself return an error, and the response must carry the
    # failure instead of raising.
    message = %{
      "type" => "tool_request",
      "tool" => "vsm_query",
      "params" => %{"system" => "s9", "query" => "status"},
      "id" => "req-error-1"
    }

    assert {:ok, response} = Handler.process(message)
    assert response["status"] == "error"
    assert is_binary(response["error"])
  end
end
