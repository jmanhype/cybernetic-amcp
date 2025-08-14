#!/usr/bin/env elixir

# Debug script to check what functions are actually exported by HermesClient
Code.require_file("lib/cybernetic/core/mcp/transports/hermes_client.ex")

module = Cybernetic.MCP.HermesClient

IO.puts("=== HermesClient Module Debug ===")
IO.puts("Module exists: #{inspect(Code.ensure_loaded(module))}")

case Code.ensure_loaded(module) do
  {:module, _} ->
    functions = module.__info__(:functions)
    IO.puts("\nExported functions:")
    Enum.each(functions, fn {name, arity} ->
      IO.puts("  #{name}/#{arity}")
    end)
    
    health_check_exported = function_exported?(module, :health_check, 0)
    IO.puts("\nhealth_check/0 exported: #{health_check_exported}")
    
    ping_exported = function_exported?(module, :ping, 0)
    IO.puts("ping/0 exported: #{ping_exported}")
    
  {:error, reason} ->
    IO.puts("Failed to load module: #{inspect(reason)}")
end