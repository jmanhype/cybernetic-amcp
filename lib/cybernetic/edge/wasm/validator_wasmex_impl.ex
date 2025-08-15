defmodule Cybernetic.Edge.WASM.Validator.WasmexImpl do
  @moduledoc false
  @behaviour Cybernetic.Edge.WASM.Behaviour

  @impl true
  def load(bytes, opts) do
    fuel = Keyword.fetch!(opts, :fuel)
    max_pages = Keyword.fetch!(opts, :max_memory_pages)

    with {:ok, store} <- Wasmex.Store.new(),
         {:ok, module} <- Wasmex.Module.compile(store, bytes),
         {:ok, instance} <-
           Wasmex.Instance.new(store, module, %{},
             fuel: fuel,
             memory_limits: %{max_pages: max_pages}
           ) do
      {:ok, instance}
    else
      {:error, r} -> {:error, r}
      other -> {:error, other}
    end
  end

  @impl true
  def validate(instance, message, opts) do
    timeout = Keyword.fetch!(opts, :timeout_ms)
    json = Jason.encode!(message)

    Wasmex.Instance.call_exported_function(instance, "validate", [json],
      timeout: timeout
    )
    |> case do
      {:ok, 0} -> :ok
      {:ok, code} when is_integer(code) -> {:error, {:wasm_error_code, code}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_return, other}}
    end
  end
end