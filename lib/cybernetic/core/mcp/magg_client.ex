defmodule Cybernetic.Core.MCP.MaggClient do
  @moduledoc """
  A minimal stdio JSON-RPC client for the Magg MCP server
  (`magg serve`, protocol 2025-06-18).

  Magg (https://github.com/sitbon/magg) is an external Python/FastMCP
  meta-MCP server — "The MCP Aggregator" — that manages, aggregates,
  and proxies other MCP servers. It runs as a separate sidecar
  process; this client is how the `Cybernetic.MCP.MAGGAdapter`
  bridge talks to it.

  The implementation mirrors `Cybernetic.Core.MCP.CraftClient`:
  newline-delimited JSON-RPC over a port with proper buffering, so
  messages of any size arrive intact. That shape exists because the
  Hermes MCP client in `hermes_mcp` 0.14.1 drops server messages
  larger than one stdio chunk (~64 KB) — a real risk here, since
  Magg's tool list grows with every aggregated backend server. It
  implements just what the bridge needs — initialize handshake,
  `tools/list`, `tools/call` — and ignores server notifications
  (including Magg's `tools/list_changed`).

  One divergence from the Craft client: the port is spawned with a
  `:cd` working directory when configured. Magg persists its server
  configuration in `.magg/config.json` relative to its working
  directory, so the bridge pins the sidecar's working directory to
  keep that state in one known place.

  Follow-up noted, deliberately not done in this branch: CraftClient
  and this client are near-identical stdio JSON-RPC implementations.
  Generalising them into one shared client is a separate refactor.
  """

  use GenServer
  require Logger

  @protocol_version "2025-06-18"
  @default_timeout 30_000

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The server's info map from the initialize handshake, or nil before it completes."
  @spec get_server_info() :: map() | nil
  def get_server_info do
    GenServer.call(__MODULE__, :get_server_info)
  end

  @doc "List the server's tools. Returns {:ok, %{\"tools\" => [...]}} or {:error, term}."
  @spec list_tools(keyword()) :: {:ok, map()} | {:error, term()}
  def list_tools(opts \\ []) do
    request("tools/list", %{}, opts)
  end

  @doc """
  Call a tool on the server. Returns {:ok, result} with the decoded
  JSON-RPC result (including its "content" and "isError" fields), or
  {:error, term}.
  """
  @spec call_tool(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call_tool(name, args \\ %{}, opts \\ []) do
    request("tools/call", %{"name" => name, "arguments" => args || %{}}, opts)
  end

  defp request(method, params, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    # The round-trip is bounded by the internal request timer, so the
    # GenServer.call itself waits a margin beyond it.
    GenServer.call(__MODULE__, {:request, method, params, timeout}, timeout + 5_000)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, ["serve"])

    case System.find_executable(command) do
      nil ->
        {:stop, {:command_not_found, command}}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, port_options(executable, args, opts))

        state = %{
          port: port,
          buffer: "",
          next_id: 1,
          pending: %{},
          server_info: nil,
          ready: false,
          waiters: []
        }

        {:ok, state, {:continue, :initialize}}
    end
  end

  # Magg keeps its configuration in .magg/config.json under its
  # working directory; pin it when the bridge config provides one.
  defp port_options(_executable, args, opts) do
    base = [:binary, :exit_status, args: args]

    case Keyword.get(opts, :cd) do
      nil -> base
      cd -> base ++ [cd: String.to_charlist(cd)]
    end
  end

  @impl true
  def handle_continue(:initialize, state) do
    params = %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "cybernetic-amcp", "version" => "0.1.0"}
    }

    {:noreply, send_request(state, "initialize", params, :initialize)}
  end

  @impl true
  def handle_call(:get_server_info, _from, state) do
    {:reply, state.server_info, state}
  end

  def handle_call({:request, method, params, timeout}, from, state) do
    if state.ready do
      {:noreply, send_request(state, method, params, {:caller, from, timeout})}
    else
      # Park callers until the handshake completes.
      {:noreply, %{state | waiters: [{method, params, from, timeout} | state.waiters]}}
    end
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    buffer = state.buffer <> chunk
    {lines, rest} = split_lines(buffer)
    state = %{state | buffer: rest}
    {:noreply, Enum.reduce(lines, state, &handle_line/2)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("MaggClient: server exited with status #{status}")
    Enum.each(state.pending, fn {_id, entry} -> reply_error(entry, :server_exited) end)
    {:stop, {:server_exited, status}, %{state | pending: %{}}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {entry, pending} ->
        reply_error(entry, :request_timeout)
        {:noreply, %{state | pending: pending}}
    end
  end

  # Private

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {lines, [rest]} = Enum.split(parts, -1)
    {Enum.reject(lines, &(&1 == "")), rest}
  end

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = message} ->
        handle_response(state, id, message)

      {:ok, %{"method" => _notification}} ->
        # Server notifications (e.g. tools/list_changed) need no action.
        state

      _other ->
        state
    end
  end

  defp handle_response(state, id, message) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {entry, pending} ->
        state = %{state | pending: pending}
        cancel_timer(entry)

        cond do
          entry.tag == :initialize and Map.has_key?(message, "result") ->
            result = message["result"]

            send_line(state.port, %{
              "jsonrpc" => "2.0",
              "method" => "notifications/initialized"
            })

            state = %{state | server_info: result["serverInfo"], ready: true}
            flush_waiters(state)

          Map.has_key?(message, "error") ->
            reply_error(entry, message["error"])
            state

          true ->
            reply_ok(entry, message["result"])
            state
        end
    end
  end

  defp flush_waiters(state) do
    Enum.reduce(Enum.reverse(state.waiters), %{state | waiters: []}, fn
      {method, params, from, timeout}, acc ->
        send_request(acc, method, params, {:caller, from, timeout})
    end)
  end

  defp send_request(state, method, params, tag) do
    id = state.next_id

    payload = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    send_line(state.port, payload)

    timeout =
      case tag do
        {:caller, _from, timeout} -> timeout
        _other -> @default_timeout
      end

    timer = Process.send_after(self(), {:request_timeout, id}, timeout)
    entry = %{tag: tag, from: caller_from(tag), timer: timer}

    %{state | next_id: id + 1, pending: Map.put(state.pending, id, entry)}
  end

  defp caller_from({:caller, from, _timeout}), do: from
  defp caller_from(_tag), do: nil

  defp send_line(port, payload) do
    Port.command(port, Jason.encode!(payload) <> "\n")
  end

  defp reply_ok(%{from: nil}, _result), do: :ok
  defp reply_ok(%{from: from}, result), do: GenServer.reply(from, {:ok, result})

  defp reply_error(%{from: nil}, _error), do: :ok
  defp reply_error(%{from: from}, error), do: GenServer.reply(from, {:error, error})

  defp cancel_timer(%{timer: timer}), do: Process.cancel_timer(timer)
end
