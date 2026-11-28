#!/usr/bin/env elixir

# Simple MCP server for testing our client
Mix.install([
  {:anubis_mcp, "~> 2.2"}
])

defmodule TestMCP.EchoTool do
  @moduledoc "Simple echo tool for testing"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field(:text, :string, required: true, description: "Text to echo back")
  end

  def execute(%{text: text}, frame) do
    result = "Echo: #{text}"
    {:reply, Response.text(Response.tool(), result), frame}
  end
end

defmodule TestMCP.Server do
  use Anubis.Server,
    name: "test-mcp-server",
    version: "1.0.0",
    capabilities: [:tools]

  component(TestMCP.EchoTool)

  def init(_client_info, frame) do
    IO.puts("🔧 TestMCP Server initialized!")
    {:ok, frame}
  end
end

IO.puts("🚀 Starting simple MCP test server...")

children = [
  {TestMCP.Server, transport: :stdio}
]

{:ok, _pid} = Supervisor.start_link(children, strategy: :one_for_one, name: TestMCP.Supervisor)

IO.puts("✅ MCP server ready! Waiting for connections...")

# Keep the server running
Process.sleep(:infinity)
