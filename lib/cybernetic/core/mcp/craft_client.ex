defmodule Cybernetic.Core.MCP.CraftClient do
  @moduledoc """
  MCP client for the Craft Anything server (`craft-anything-cli mcp`,
  stdio transport, protocol 2025-06-18).

  This is a real client built on the Hermes MCP library — unlike
  `Cybernetic.MCP.HermesClient`, which is a plugin-shaped stub whose
  `call_tool/3` returns `{:error, :not_implemented}`.

  Started by `Cybernetic.Core.MCP.CraftBridge` when the
  `:craft_mcp` config gate is enabled; see that module for the
  registration flow that exposes Craft's tools through the Hermes
  tool registry.
  """

  use Hermes.Client,
    name: "cybernetic-amcp",
    version: "0.1.0",
    protocol_version: "2025-06-18",
    capabilities: []
end
