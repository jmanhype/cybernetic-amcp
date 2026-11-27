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
        start_supervised!({CraftClient, command: executable, args: ["--deep", "mcp"]})

        assert {:ok, count} = CraftBridge.register_tools()
        # Essentials alone lists ~30 tools; with the native and
        # browser toolsets enabled in Deep mode the server lists 100+.
        assert count >= 100

        assert {:ok, tool} = Registry.get_tool("craft_core_session_show")
        assert tool.metadata.remote_name == "core_session_show"

        # One tool from each widened toolset is registered.
        assert {:ok, _} = Registry.get_tool("craft_native_call_graph_show")
        assert {:ok, _} = Registry.get_tool("craft_web_site_open")

        assert {:ok, result} = Registry.invoke_tool("craft_core_session_show", %{})
        assert is_map(result)

        text =
          result
          |> Map.get("content", [])
          |> Enum.map_join(" ", fn item -> item["text"] || "" end)

        assert text =~ "0.6"
    end
  end

  test "registry restart: craft tools re-register without restarting the bridge" do
    case craft_executable() do
      nil ->
        IO.puts("craft-anything-cli not found; skipping registry-restart test")

      executable ->
        bridge_pid =
          start_supervised!({CraftBridge, command: executable, args: ["--deep", "mcp"]})

        # Initial registration completes through the bridge itself:
        # wait until its state reports the registered count, so the
        # kill below lands on an idle bridge, not a mid-registration
        # one.
        assert wait_until(fn ->
                 :sys.get_state(bridge_pid).registered > 0
               end),
               "craft tools never registered initially"

        assert {:ok, _} = Registry.get_tool("craft_core_session_show")

        {:ok, tools_before} = Registry.list_tools()
        craft_before = Enum.count(tools_before, &String.starts_with?(&1.name, "craft_"))
        assert craft_before >= 100

        # Restart the Hermes registry. It is an app-supervised
        # child (it belongs to the minimal test tree), so killing
        # it makes the application supervisor bring back a fresh
        # instance whose new ETS table starts empty — every craft_*
        # registration is lost with the old process. The pid change
        # is the proof of the wipe: the table is created in the
        # registry's init and owned by that process.
        registry_pid = Process.whereis(Registry)
        Process.exit(registry_pid, :kill)

        assert wait_until(fn ->
                 case Process.whereis(Registry) do
                   nil -> false
                   ^registry_pid -> false
                   _new_pid -> true
                 end
               end),
               "registry never restarted"

        :ok = Registry.await_ready(2_000)

        # The bridge — same pid, never restarted — restores the
        # tools when the fresh registry's :ready event fires. Wait
        # for the full set to return, not just the first tool: the
        # re-registration streams all 115 in one by one.
        assert wait_until(
                 fn ->
                   {:ok, tools} = Registry.list_tools()
                   Enum.count(tools, &String.starts_with?(&1.name, "craft_")) >= craft_before
                 end,
                 240
               ),
               "craft tools never returned after the registry restart"

        assert Process.whereis(CraftBridge) == bridge_pid
    end
  end

  # Poll `fun` every 250 ms until it returns truthy or the deadline
  # (30 s by default) passes. Registration against the real Craft
  # server takes seconds, and this VM is heavily contended.
  defp wait_until(fun, attempts \\ 120)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(250)
      wait_until(fun, attempts - 1)
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
