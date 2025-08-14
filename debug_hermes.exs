#!/usr/bin/env elixir

Mix.install([], force: true)

# Force compilation of the module
Code.require_file("lib/cybernetic/core/mcp/transports/hermes_client.ex")

module = Cybernetic.MCP.HermesClient

IO.puts("=== HermesClient Function Analysis ===")
case Code.ensure_loaded(module) do
  {:module, _} ->
    functions = module.__info__(:functions)
    IO.puts("\nAll exported functions (#{length(functions)}):")
    
    functions 
    |> Enum.sort() 
    |> Enum.each(fn {name, arity} -> 
      IO.puts("  #{name}/#{arity}")
    end)
    
    # Test the specific functions the tests expect
    expected_functions = [
      {:ping, 0},
      {:list_tools, 0}, 
      {:call_tool, 2},
      {:read_resource, 1},
      {:get_available_tools, 0},
      {:metadata, 0},
      {:process, 2},
      {:handle_event, 2}
    ]
    
    IO.puts("\nExpected function status:")
    Enum.each(expected_functions, fn {name, arity} ->
      exported = function_exported?(module, name, arity)
      status = if exported, do: "✅ FOUND", else: "❌ MISSING"
      IO.puts("  #{name}/#{arity}: #{status}")
    end)
    
  {:error, reason} ->
    IO.puts("Failed to load module: #{inspect(reason)}")
end