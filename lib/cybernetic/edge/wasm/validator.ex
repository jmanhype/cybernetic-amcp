defmodule Cybernetic.Edge.WASM.Validator do
  @moduledoc """
  Loads and runs WASM validators to pre-validate messages at the edge.

  Default export expected in WASM: `(func (export "validate") (param i32 i32) (result i32))`
  where the param pair points to a UTF-8 JSON slice of the message; return 0 = ok, nonzero = error.
  """
  @behaviour Cybernetic.Edge.WASM.Behaviour
  require Logger

  @telemetry [:cybernetic, :edge, :wasm, :validate]
  @default_limits [fuel: 5_000_000, timeout_ms: 50, max_memory_pages: 64]

  @impl true
  def load(bytes, opts \\ []) when is_binary(bytes) do
    # User opts should override defaults
    impl().load(bytes, Keyword.merge(opts, @default_limits))
  end

  @impl true
  def validate(instance, message, opts \\ []) when is_map(message) do
    start = System.monotonic_time()
    :telemetry.execute(@telemetry ++ [:start], %{count: 1}, %{opts: opts})

    # User opts should override defaults
    res = impl().validate(instance, message, Keyword.merge(opts, @default_limits))

    :telemetry.execute(
      @telemetry ++ [:stop],
      %{duration: System.monotonic_time() - start},
      %{result: res}
    )

    res
  rescue
    e ->
      :telemetry.execute(@telemetry ++ [:exception], %{count: 1}, %{error: e})
      {:error, {:exception, e}}
  end

  # pick an implementation at runtime
  defp impl do
    cond do
      # Check if wasmtime CLI is available
      System.find_executable("wasmtime") != nil ->
        Cybernetic.Edge.WASM.Validator.PortImpl
        
      # Fallback to Wasmex if available
      Code.ensure_loaded?(Wasmex) ->
        Cybernetic.Edge.WASM.Validator.WasmexImpl
        
      # Default to no-op
      true ->
        Cybernetic.Edge.WASM.Validator.NoopImpl
    end
  end
end