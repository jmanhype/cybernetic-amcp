Mix.install([])
alias Cybernetic.MCP.HermesClient

IO.puts("=== Module Info ===")
try do
  case Code.ensure_loaded(HermesClient) do
    {:module, _} ->
      IO.puts("Module loaded successfully")
      
      functions = HermesClient.__info__(:functions)
      IO.puts("\nAll functions (#{length(functions)}):")
      functions 
      |> Enum.sort() 
      |> Enum.each(fn {name, arity} -> 
        IO.puts("  #{name}/#{arity}")
      end)
      
      IO.puts("\nChecking specific functions:")
      IO.puts("health_check/0 exported: #{function_exported?(HermesClient, :health_check, 0)}")
      IO.puts("ping/0 exported: #{function_exported?(HermesClient, :ping, 0)}")
      IO.puts("process/2 exported: #{function_exported?(HermesClient, :process, 2)}")
      
    {:error, reason} ->
      IO.puts("Failed to load: #{inspect(reason)}")
  end
rescue
  error ->
    IO.puts("Error: #{inspect(error)}")
end