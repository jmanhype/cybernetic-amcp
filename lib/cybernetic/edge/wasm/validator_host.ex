defmodule Cybernetic.Edge.WASM.ValidatorHost do
  @moduledoc """
  Loads and runs WASM validator modules (compiled to `wasm32-wasi`).
  Each instance maintains its own store/state for deterministic, sandboxed checks.
  """
  use GenServer
  require Logger

  @type wasm_path :: binary()
  @type func :: binary()

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @impl true
  def init(opts) do
    {:ok,
     %{
       path: opts[:wasm_path] || System.get_env("CYB_WASM_VALIDATOR") || "priv/validator.wasm",
       func: opts[:func] || "validate",
       instance: nil
     }, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    case load_instance(state.path) do
      {:ok, instance} ->
        :telemetry.execute([:cybernetic, :wasm, :loaded], %{ok: 1}, %{path: state.path})
        {:noreply, %{state | instance: instance}}

      {:error, reason} ->
        Logger.error("WASM load failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @doc """
  Validates a normalized message. Returns :ok or {:error, reason}.
  """
  def validate(server \\ __MODULE__, msg) do
    GenServer.call(server, {:validate, msg}, 2_000)
  end

  @impl true
  def handle_call({:validate, msg}, _from, %{instance: nil} = s) do
    {:reply, {:error, :not_loaded}, s}
  end

  def handle_call({:validate, msg}, _from, %{instance: {mod, pid}, func: func} = s) do
    payload = Jason.encode!(msg)
    # The wasm function signature is `i32,i32 -> i32` length-delimited via WASI-stdout
    case mod.call(pid, func, [payload]) do
      {:ok, "OK"} ->
        {:reply, :ok, s}

      {:ok, "REJECT:" <> reason} ->
        {:reply, {:error, String.trim(reason)}, s}

      other ->
        {:reply, {:error, {:unexpected, other}}, s}
    end
  end

  # ——— internals ———

  defp load_instance(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, pid} <- Wasmex.start_link(%Wasmex.WasmModule{bytes: bin}, wasi: true) do
      {:ok, {__MODULE__.Runner, pid}}
    end
  end

  # Thin wrapper to isolate call mechanics (easy to swap engines later)
  defmodule Runner do
    def call(pid, func, [json_payload]) do
      # Assume exported `validate(ptr,len) -> status` writing "OK" or "REJECT:..." to stdout
      Wasmex.call_function(pid, func, [json_payload])
    end
  end
end