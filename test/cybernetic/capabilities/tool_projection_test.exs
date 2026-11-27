defmodule Cybernetic.Capabilities.ToolProjectionTest do
  @moduledoc """
  Boundary tests for Axiomatic Design coupling #9 (Issue #86):
  Hermes owns registration + invocation, Capabilities owns
  discovery, and `ToolProjection` bridges them one-way.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Capabilities.Registry, as: CapabilitiesRegistry
  alias Cybernetic.Capabilities.ToolProjection
  alias Cybernetic.Core.MCP.Hermes.Registry, as: HermesRegistry
  alias Cybernetic.Core.MCP.Server

  setup do
    start_supervised!(CapabilitiesRegistry)
    :ok
  end

  defp hermes_tools do
    {:ok, tools} = HermesRegistry.list_tools()
    Enum.sort_by(tools, & &1.name)
  end

  defp hermes_tool_names, do: Enum.map(hermes_tools(), & &1.name)

  defp eventually(fun, attempts \\ 30)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end

  test "catch-up projects builtin Hermes tools and discover/2 finds generate_nonce" do
    start_supervised!(ToolProjection)

    assert {:ok, count} = ToolProjection.resync()
    # At least the six Hermes builtins are mirrored.
    assert count >= 6

    assert {:ok, cap} = CapabilitiesRegistry.get_by_name("generate_nonce")
    assert cap.provider == HermesRegistry
    assert cap.metadata.mcp_tool == "generate_nonce"
    assert cap.metadata.source == :hermes
    assert cap.metadata.projected_from == :hermes_registry
    assert is_list(cap.embedding)

    assert {:ok, results} = CapabilitiesRegistry.discover("cryptographic nonce", threshold: 0.3)
    assert Enum.any?(results, &(&1.name == "generate_nonce"))
  end

  test "a tool registered into Hermes at runtime is projected via the telemetry event" do
    start_supervised!(ToolProjection)
    assert {:ok, _count} = ToolProjection.resync()

    name = "projection_probe_#{System.unique_integer([:positive])}"

    assert {:ok, _tool} =
             HermesRegistry.register_tool(
               name,
               "Frobnicate the projection probe widget",
               %{},
               {String, :to_string},
               capabilities: ["probe", "frobnicate"]
             )

    # No restart, no manual resync: the registration event drives it.
    assert eventually(fn ->
             match?({:ok, _cap}, CapabilitiesRegistry.get_by_name(name))
           end),
           "expected #{name} to be projected via the tool_registered event"

    assert {:ok, cap} = CapabilitiesRegistry.get_by_name(name)
    assert cap.metadata.source == :hermes
    assert is_list(cap.embedding)

    assert {:ok, results} =
             CapabilitiesRegistry.discover("frobnicate projection probe widget", threshold: 0.3)

    assert Enum.any?(results, &(&1.name == name))
  end

  test "re-running catch-up creates no duplicate capability records" do
    start_supervised!(ToolProjection)

    assert {:ok, _} = ToolProjection.resync()
    first = CapabilitiesRegistry.list()

    assert {:ok, _} = ToolProjection.resync()
    second = CapabilitiesRegistry.list()

    assert length(second) == length(first)
    names = Enum.map(second, & &1.name)
    assert names == Enum.uniq(names)
    assert Enum.count(second, &(&1.name == "generate_nonce")) == 1
  end

  test "projection never writes into Hermes" do
    before = hermes_tools()

    start_supervised!(ToolProjection)
    assert {:ok, _} = ToolProjection.resync()

    assert hermes_tools() == before
  end

  test "projection skips a name owned by a manually registered capability" do
    assert {:ok, manual} =
             CapabilitiesRegistry.register(%{
               name: "crdt_merge",
               description: "Manual capability, not a projection",
               provider: ManualMod
             })

    start_supervised!(ToolProjection)
    assert {:ok, _} = ToolProjection.resync()

    assert {:ok, still} = CapabilitiesRegistry.get_by_name("crdt_merge")
    assert still.id == manual.id
    assert still.provider == ManualMod
  end

  test "MCP.Server init registers nothing into Hermes (capture-handler landmine removed)" do
    before = hermes_tool_names()

    assert {:ok, %{}} = Server.init(nil, %{})

    assert hermes_tool_names() == before
    refute "telemetry_probe" in hermes_tool_names()
  end
end
