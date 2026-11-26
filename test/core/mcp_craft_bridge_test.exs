defmodule Cybernetic.Core.MCP.CraftBridgeTest.FakeForwarder do
  @moduledoc false
  def forward(remote_name, params, context) do
    %{remote_name: remote_name, params: params, context: context}
  end
end

defmodule Cybernetic.Core.MCP.CraftBridgeTest.RaisingForwarder do
  @moduledoc false
  def forward(_remote_name, _params, _context), do: raise("boom from remote")
end

defmodule Cybernetic.Core.MCP.CraftBridgeTest do
  @moduledoc """
  Tests for the Craft Anything MCP bridge (Issue #86 follow-up).

  Covers the registry's `{:forward, module, remote_name}` dispatch —
  the mechanism external MCP servers are registered with — and an
  end-to-end run against the real `craft-anything-cli mcp` server
  when the binary is available.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Core.MCP.CraftBridge
  alias Cybernetic.Core.MCP.CraftClient
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

  test "forward handler receives the remote name, params and context" do
    assert {:ok, _tool} =
             Registry.register_tool(
               "fake_echo",
               "echoes through the forwarder",
               %{},
               {:forward, __MODULE__.FakeForwarder, "remote_echo"}
             )

    assert {:ok, result} =
             Registry.invoke_tool("fake_echo", %{q: "x"}, %{caller: :test})

    assert result.remote_name == "remote_echo"
    assert result.params == %{q: "x"}
    assert result.context == %{caller: :test}
  end

  test "forward handler errors reach the caller as {:error, message}" do
    assert {:ok, _tool} =
             Registry.register_tool(
               "fake_raiser",
               "always raises",
               %{},
               {:forward, __MODULE__.RaisingForwarder, "remote_boom"}
             )

    assert {:error, message} = Registry.invoke_tool("fake_raiser", %{})
    assert message =~ "boom from remote"
  end

  test "real Craft Anything server: tools register and a call round-trips" do
    case craft_executable() do
      nil ->
        IO.puts("craft-anything-cli not found; skipping live Craft bridge test")

      executable ->
        start_supervised!({CraftClient, transport: {:stdio, command: executable, args: ["mcp"]}})

        assert {:ok, count} = CraftBridge.register_tools()
        assert count >= 10

        assert {:ok, tool} = Registry.get_tool("craft_core_session_show")
        assert tool.metadata.remote_name == "core_session_show"

        assert {:ok, result} = Registry.invoke_tool("craft_core_session_show", %{})
        assert is_map(result)

        text =
          result
          |> Map.get("content", [])
          |> Enum.map_join(" ", fn item -> item["text"] || "" end)

        assert text =~ "0.6"
    end
  end

  defp craft_executable do
    candidates = [
      System.find_executable("craft-anything-cli"),
      Path.expand("~/.local/bin/craft-anything-cli")
    ]

    Enum.find(candidates, fn
      nil -> false
      path -> File.exists?(path)
    end)
  end
end
