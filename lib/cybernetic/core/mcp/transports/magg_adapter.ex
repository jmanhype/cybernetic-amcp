defmodule Cybernetic.MCP.MAGGAdapter do
  @moduledoc """
  Bridges the external Magg MCP server into the Hermes tool
  registry.

  ## What Magg is

  Magg (https://github.com/sitbon/magg) — "The MCP Aggregator" — is
  a Python/FastMCP meta-MCP server that manages, aggregates, and
  proxies other MCP servers: backends are added, removed, enabled,
  and disabled dynamically through Magg's own `magg_*` tools, and
  their tools are exposed through Magg under per-server prefixes.
  It is, in effect, a package manager for MCP servers.

  ## Sidecar arrangement

  Magg is AGPL-3.0 and runs as a **separate process** — no Magg code
  is part of this repository. The bridge spawns `magg serve` over
  stdio via `Cybernetic.Core.MCP.MaggClient` and speaks MCP
  JSON-RPC to it, exactly like the Craft Anything bridge
  (`Cybernetic.Core.MCP.CraftBridge`) does for its server.

  On this machine Magg lives in a Python venv at
  `~/workspace/magg-sidecar/venv` (installed with
  `pip install magg`, version 1.3.0), and the bridge binary is
  `~/workspace/magg-sidecar/venv/bin/magg`.

  ## What the bridge does

  On start (only when `config :cybernetic, :magg, enabled: true`)
  the bridge:

    1. starts `Cybernetic.Core.MCP.MaggClient` connected to
       `magg serve` over stdio,
    2. lists Magg's tools,
    3. registers each one in `Cybernetic.Core.MCP.Hermes.Registry`
       under a `magg_`-prefixed name with a
       `{:forward, __MODULE__, remote_name}` handler.

  **All** of Magg's tools are registered — its `magg_*` management
  tools (add/remove/enable/disable/search servers, kits, status)
  as well as every aggregated backend tool (which Magg already
  exposes under the backend's prefix, e.g. `echo_echo` for an
  `echo` backend's `echo` tool, registered here as
  `magg_echo_echo`). Dynamic server management is the point of
  Magg, so nothing is filtered out.

  Invocations through the registry are dispatched by the registry's
  forward clause to `forward/3` here, which calls the tool on the
  Magg server and returns its result. Errors follow the registry's
  handler contract: `forward/3` raises on transport or tool errors
  and the registry converts the exception into `{:error, message}`.

  Because registrations flow into the Hermes registry, the
  coupling-#9 projection
  (`Cybernetic.Capabilities.ToolProjection`) mirrors the Magg tools
  into the Capabilities registry automatically — discovery comes
  for free.

  ## Registry restarts

  The Hermes registry holds tools in ETS owned by the registry
  process; if it restarts, every registration is lost. The bridge
  subscribes to the registry's
  `[:cybernetic, :mcp_registry, :ready]` telemetry event and
  re-runs registration when it fires (registration is an ETS
  upsert by name, so re-running is idempotent). Magg tools
  therefore survive a registry restart without the bridge
  restarting.

  ## Configuration and state

  The bridge is disabled by default; the application only starts
  it in the full (non-minimal) supervision tree when the config
  gate is on:

      config :cybernetic, :magg,
        enabled: false,
        command: "/home/hatch/workspace/magg-sidecar/venv/bin/magg",
        args: ["serve"],
        cd: "/home/hatch/workspace/magg-sidecar"

  Magg persists its server configuration in `.magg/config.json`
  **relative to its working directory**, so the `:cd` option pins
  the sidecar's working directory — servers added through the
  `magg_magg_add_server` tool survive restarts of both Magg and
  this application. If the Magg binary is missing or fails to
  start, the bridge logs the failure and idles: Magg tools are
  unavailable, but boot is never blocked or crashed.
  """

  use GenServer
  require Logger

  alias Cybernetic.Core.MCP.Hermes.Registry
  alias Cybernetic.Core.MCP.MaggClient

  @default_timeout 30_000
  @default_args ["serve"]
  @register_delay_ms 200
  @max_register_attempts 10
  @ready_event [:cybernetic, :mcp_registry, :ready]

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Registry forward handler: call `remote_name` on the Magg MCP
  server with `params` and return the tool result.

  Atom-keyed params (the shape used by in-process callers) are
  converted to the string keys JSON-RPC expects.
  """
  @spec forward(String.t(), map() | nil, map()) :: map()
  def forward(remote_name, params, _context) do
    arguments = stringify_keys(params || %{})

    case MaggClient.call_tool(remote_name, arguments, timeout: @default_timeout) do
      {:ok, result} ->
        unwrap_result(result, remote_name)

      {:error, error} ->
        raise RuntimeError,
              "Magg tool #{remote_name} call failed: #{inspect(error)}"
    end
  end

  @doc """
  List Magg's tools and register each in the Hermes registry.
  Returns `{:ok, count}` or `{:error, reason}`.
  """
  @spec register_tools(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def register_tools(_config \\ magg_config()) do
    with :ok <- await_client_ready(40) do
      do_register_tools()
    end
  end

  @doc false
  def handle_telemetry_event(@ready_event, _measurements, _metadata, pid) do
    send(pid, :registry_ready)
  end

  def handle_telemetry_event(_event, _measurements, _metadata, _pid), do: :ok

  # GenServer callbacks

  @impl true
  def init(opts) do
    # The client is started linked from init. On this OTP, a
    # GenServer whose init returns {:stop, reason} propagates an
    # EXIT to a non-trapping start_link caller instead of simply
    # returning {:error, reason} - so without trapping, a missing
    # Magg binary would kill the bridge (and crash-loop its
    # supervisor) instead of degrading to a logged absence.
    Process.flag(:trap_exit, true)

    config = Keyword.merge(magg_config(), opts)
    handler_id = attach_ready_handler()

    state = %{
      config: config,
      attempts: 0,
      registered: 0,
      client_started: false,
      client_pid: nil,
      handler_id: handler_id
    }

    case ensure_client_started(config) do
      {:ok, pid} ->
        Process.send_after(self(), :register_tools, @register_delay_ms)
        {:ok, %{state | client_started: true, client_pid: pid}}

      {:error, reason} ->
        Logger.error("MAGGAdapter: could not start Magg MCP client: #{inspect(reason)}")
        {:ok, %{state | attempts: @max_register_attempts}}
    end
  end

  @impl true
  def handle_info(:register_tools, %{attempts: attempts} = state)
      when attempts >= @max_register_attempts do
    Logger.error(
      "MAGGAdapter: giving up registering Magg tools after #{attempts} attempts; " <>
        "Magg tools will be unavailable"
    )

    {:noreply, state}
  end

  def handle_info(:register_tools, state) do
    with :ok <- Registry.await_ready(2_000),
         {:ok, count} <- register_tools(state.config) do
      Logger.info("MAGGAdapter: registered #{count} Magg tools")
      {:noreply, %{state | registered: count, attempts: 0}}
    else
      other ->
        Logger.warning(
          "MAGGAdapter: registration attempt #{state.attempts + 1} failed: #{inspect(other)}; retrying"
        )

        Process.send_after(self(), :register_tools, 1_000)
        {:noreply, %{state | attempts: state.attempts + 1}}
    end
  end

  # The linked Magg client died (e.g. the sidecar process
  # exited). Degrade: Magg tools stop answering, the bridge stays
  # up, and a later registration cycle can restart the client.
  def handle_info({:EXIT, pid, reason}, %{client_pid: pid} = state) when is_pid(pid) do
    Logger.error("MAGGAdapter: Magg client exited: #{inspect(reason)}")
    {:noreply, %{state | client_started: false, client_pid: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # The Hermes registry restarted and re-registered its builtins:
  # re-register the Magg tools (an idempotent ETS upsert by name)
  # so they are not silently lost.
  def handle_info(:registry_ready, %{client_started: true} = state) do
    Process.send_after(self(), :register_tools, @register_delay_ms)
    {:noreply, %{state | attempts: 0}}
  end

  def handle_info(:registry_ready, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.handler_id, do: :telemetry.detach(state.handler_id)
    :ok
  end

  # Private

  defp magg_config do
    Application.get_env(:cybernetic, :magg, [])
  end

  defp attach_ready_handler do
    handler_id = "magg-adapter-registry-ready-#{inspect(self())}"

    case :telemetry.attach(handler_id, @ready_event, &__MODULE__.handle_telemetry_event/4, self()) do
      :ok ->
        handler_id

      {:error, :already_exists} ->
        Logger.warning(
          "MAGGAdapter: telemetry handler #{inspect(handler_id)} already attached; continuing"
        )

        handler_id
    end
  end

  defp ensure_client_started(config) do
    command = Keyword.get(config, :command, "magg")
    args = Keyword.get(config, :args, @default_args)
    cd = Keyword.get(config, :cd)

    case MaggClient.start_link(command: command, args: args, cd: cd) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # The client connects asynchronously: until the initialize
  # handshake completes, get_server_info/0 returns nil.
  defp await_client_ready(0), do: {:error, :magg_client_not_ready}

  defp await_client_ready(attempts) do
    if MaggClient.get_server_info() do
      :ok
    else
      Process.sleep(250)
      await_client_ready(attempts - 1)
    end
  end

  defp do_register_tools do
    case MaggClient.list_tools(timeout: @default_timeout) do
      {:ok, %{"tools" => tools}} when is_list(tools) ->
        Enum.each(tools, &register_tool/1)
        {:ok, length(tools)}

      {:ok, other} ->
        {:error, {:unexpected_list_tools_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp register_tool(%{"name" => remote_name} = tool) do
    Registry.register_tool(
      "magg_" <> remote_name,
      tool["description"] || "",
      tool["inputSchema"] || %{},
      {:forward, __MODULE__, remote_name},
      capabilities: ["magg", "external"],
      metadata: %{source: "magg", remote_name: remote_name}
    )
  end

  defp unwrap_result(result, remote_name) do
    if Map.get(result, "isError", false) do
      raise RuntimeError,
            "Magg tool #{remote_name} returned an error: #{inspect(result)}"
    end

    result
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} -> {key, stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)

  defp stringify_value(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp stringify_value(value), do: value
end
