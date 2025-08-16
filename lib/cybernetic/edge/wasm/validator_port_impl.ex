defmodule Cybernetic.Edge.WASM.Validator.PortImpl do
  @moduledoc """
  Production WASM validator using external wasmtime CLI via Port.
  
  This avoids rustler dependency conflicts while providing full WASM security.
  Requires wasmtime CLI to be installed: https://wasmtime.dev/
  """
  @behaviour Cybernetic.Edge.WASM.Behaviour
  require Logger
  
  # Find wasmtime at runtime, not compile time
  defp wasmtime_path do
    System.find_executable("wasmtime") || "/usr/local/bin/wasmtime"
  end
  @telemetry [:cybernetic, :wasm, :port]
  
  @impl true
  def load(wasm_bytes, opts) do
    # Write WASM to temporary file
    temp_path = Path.join(System.tmp_dir!(), "validator_#{:erlang.unique_integer([:positive])}.wasm")
    File.write!(temp_path, wasm_bytes)
    
    # Verify WASM is valid
    case System.cmd(wasmtime_path(), ["compile", temp_path]) do
      {_, 0} ->
        {:ok, %{
          wasm_path: temp_path,
          fuel_limit: Keyword.get(opts, :fuel, 5_000_000),
          max_memory: Keyword.get(opts, :max_memory_pages, 64)
        }}
      {error, _} ->
        File.rm(temp_path)
        {:error, {:invalid_wasm, error}}
    end
  rescue
    e ->
      {:error, {:load_failed, e}}
  end
  
  @impl true
  def validate(validator_state, message, opts) do
    %{wasm_path: wasm_path, fuel_limit: fuel, max_memory: max_mem} = validator_state
    timeout = Keyword.get(opts, :timeout_ms, 50)
    
    # Prepare JSON input
    json_input = Jason.encode!(message)
    
    # Build wasmtime command with security constraints
    args = [
      "run",
      "--fuel", to_string(fuel),
      "--max-memory-size", "#{max_mem * 64 * 1024}",  # pages to bytes
      # No --dir flag means no filesystem access
      "--env", "WASM_ENV=secure",
      wasm_path,
      "--",
      json_input
    ]
    
    # Run with timeout using Port
    port = Port.open({:spawn_executable, @wasmtime_path}, [
      :binary,
      :exit_status,
      args: args,
      line: 1024
    ])
    
    # Set timeout
    Process.send_after(self(), {:kill_port, port}, timeout)
    
    start_time = System.monotonic_time(:microsecond)
    result = collect_port_output(port, timeout)
    duration = System.monotonic_time(:microsecond) - start_time
    
    :telemetry.execute(
      @telemetry ++ [:executed],
      %{duration_us: duration},
      %{result: elem(result, 0)}
    )
    
    case result do
      {:ok, output} ->
        parse_validation_result(output, duration)
      {:error, :timeout} ->
        {:error, :validation_timeout}
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  # Private functions
  
  defp collect_port_output(port, timeout) do
    collect_port_output(port, timeout, [])
  end
  
  defp collect_port_output(port, timeout, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, timeout, [data | acc])
        
      {^port, {:exit_status, 0}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, output}
        
      {^port, {:exit_status, code}} ->
        {:error, {:wasm_exit, code}}
        
      {:kill_port, ^port} ->
        Port.close(port)
        {:error, :timeout}
        
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end
  
  defp parse_validation_result(output, duration) do
    # Parse WASM output - expecting "0" for valid or error code
    case String.trim(output) do
      "0" ->
        {:ok, %{valid: true, duration_us: duration}}
      error_code when error_code =~ ~r/^\d+$/ ->
        {:error, %{
          valid: false,
          error_code: String.to_integer(error_code),
          error_message: decode_error(String.to_integer(error_code)),
          duration_us: duration
        }}
      other ->
        Logger.warning("Unexpected WASM output: #{inspect(other)}")
        {:error, {:invalid_output, other}}
    end
  end
  
  defp decode_error(code) do
    case code do
      1 -> "Invalid JSON input"
      2 -> "Missing required field"
      3 -> "Invalid signature"
      4 -> "Expired timestamp"
      5 -> "Invalid nonce"
      _ -> "Unknown error: #{code}"
    end
  end
end