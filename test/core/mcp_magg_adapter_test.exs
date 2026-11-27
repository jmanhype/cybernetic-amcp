defmodule Cybernetic.MCP.MAGGAdapterTest do
  @moduledoc """
  Tests for the Magg MCP aggregator bridge.

  Covers the degraded path (missing sidecar binary must never
  crash the bridge) and, when the Magg sidecar is installed, an
  end-to-end run against the real `magg serve` process: tools
  register with the `magg_` prefix, a management tool round-trips
  through the Hermes registry, an aggregated backend tool flows
  through, and the bridge re-registers on the registry `:ready`
  event (the registry-restart heal).
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Core.MCP.Hermes.Registry
  alias Cybernetic.Core.MCP.MaggClient
  alias Cybernetic.MCP.MAGGAdapter

  @sidecar_dir Path.expand("~/workspace/magg-sidecar")

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

  test "bridge idles without crashing when the Magg binary is missing" do
    start_supervised!({MAGGAdapter, command: "/nonexistent/magg", args: ["serve"]})

    # Degraded means: the bridge stays alive (no crash loop under
    # the supervisor) and no client process exists. (Deliberately
    # not a registry assertion: registrations from other tests in
    # this module persist in the shared registry, so tool absence
    # is not this test's property to assert.)
    Process.sleep(300)
    assert Process.alive?(Process.whereis(MAGGAdapter))
    assert Process.whereis(MaggClient) == nil
    Process.sleep(300)
    assert Process.alive?(Process.whereis(MAGGAdapter))
  end

  @tag timeout: 300_000
  test "real Magg server: tools register and a management call round-trips" do
    case magg_executable() do
      nil ->
        IO.puts("Magg sidecar not found; skipping live Magg bridge test")

      executable ->
        config = [command: executable, args: ["serve"], cd: @sidecar_dir]
        start_supervised!({MaggClient, config})

        assert {:ok, count} = MAGGAdapter.register_tools(config)
        # A bare Magg exposes 16 tools (proxy + 15 magg_*); mounted
        # backends add more.
        assert count >= 16

        assert {:ok, tool} = Registry.get_tool("magg_magg_status")
        assert tool.metadata.remote_name == "magg_status"
        assert tool.metadata.source == "magg"
        assert {:ok, _} = Registry.get_tool("magg_magg_list_servers")
        assert {:ok, _} = Registry.get_tool("magg_magg_add_server")

        assert {:ok, result} = Registry.invoke_tool("magg_magg_status", %{})
        text = result_text(result)
        assert text =~ "\"tools\""
        assert text =~ "\"servers\""
    end
  end

  @tag timeout: 300_000
  test "aggregated backend flows through; :ready event heals registration" do
    case magg_executable() do
      nil ->
        IO.puts("Magg sidecar not found; skipping live Magg aggregation test")

      executable ->
        config = [command: executable, args: ["serve"], cd: @sidecar_dir]
        start_supervised!({MAGGAdapter, config})

        # The bridge's own initial registration completes.
        assert wait_for(fn -> match?({:ok, _}, Registry.get_tool("magg_magg_status")) end)

        # Add a backend directly on Magg, behind the bridge's back.
        # A unique prefix keeps the resulting tool name unique to
        # this run, so the assertions hold regardless of registry
        # persistence or test order.
        uniq = "echo#{System.unique_integer([:positive])}"
        remote_tool = "#{uniq}_echo"
        registered_name = "magg_" <> remote_tool

        assert {:error, :not_found} = Registry.get_tool(registered_name)

        assert {:ok, add_result} =
                 MaggClient.call_tool("magg_add_server", %{
                   "name" => uniq,
                   "source" => "https://example.invalid/echo-backend",
                   "command" => "#{@sidecar_dir}/venv/bin/python #{@sidecar_dir}/echo_server.py",
                   "prefix" => uniq
                 })

        refute Map.get(add_result, "isError", false)

        # Not registered yet: the bridge only learns about tools
        # when it (re-)registers.
        assert {:error, :not_found} = Registry.get_tool(registered_name)

        # Simulate a Hermes registry restart: it emits :ready after
        # re-registering its builtins, and the bridge re-registers
        # in response.
        :telemetry.execute([:cybernetic, :mcp_registry, :ready], %{count: 0}, %{})

        assert wait_for(fn -> match?({:ok, _}, Registry.get_tool(registered_name)) end),
               "bridge did not re-register after the registry :ready event"

        assert {:ok, result} = Registry.invoke_tool(registered_name, %{text: "hello-magg"})
        assert result_text(result) =~ "echo-backend: hello-magg"

        # Best-effort cleanup: unmount the throwaway backend so the
        # sidecar's persisted config returns to its prior state.
        _ = MaggClient.call_tool("magg_remove_server", %{"name" => uniq})
    end
  end

  defp magg_executable do
    path = Path.join(@sidecar_dir, "venv/bin/magg")
    if File.exists?(path), do: path, else: nil
  end

  defp result_text(result) do
    result
    |> Map.get("content", [])
    |> Enum.map_join(" ", fn item -> item["text"] || "" end)
  end

  defp wait_for(fun, attempts \\ 60, interval \\ 500) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(interval)
        wait_for(fun, attempts - 1, interval)
    end
  end
end
