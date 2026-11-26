defmodule Cybernetic.Core.MCP.CraftBridge do
  @moduledoc """
  Bridges the external Craft Anything MCP server into the Hermes
  tool registry.

  On start (only when `config :cybernetic, :craft_mcp, enabled: true`)
  the bridge:

    1. starts `Cybernetic.Core.MCP.CraftClient` connected to
       `craft-anything-cli mcp` over stdio,
    2. lists the server's tools,
    3. registers each one in `Cybernetic.Core.MCP.Hermes.Registry`
       under a `craft_`-prefixed name with a
       `{:forward, __MODULE__, remote_name}` handler.

  Invocations through the registry are dispatched by the registry's
  forward clause to `forward/3` here, which calls the tool on the
  Craft server and returns its result — so, combined with the MCP
  result path fix, a caller of `Registry.invoke_tool/3` receives the
  Craft tool's actual output.

  Errors follow the registry's existing handler contract: `forward/3`
  raises on transport or tool errors and the registry converts the
  exception into `{:error, message}` for the caller.

  The bridge is disabled by default; the application only starts it
  in the full (non-minimal) supervision tree when the config gate is
  on, so default boot and the test suite are unaffected.
  """

  use GenServer
  require Logger

  alias Cybernetic.Core.MCP.CraftClient
  alias Cybernetic.Core.MCP.Hermes.Registry

  @default_timeout 30_000
  @register_delay_ms 200
  @max_register_attempts 10

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Registry forward handler: call `remote_name` on the Craft MCP
  server with `params` and return the tool result.

  Atom-keyed params (the shape used by in-process callers) are
  converted to the string keys JSON-RPC expects.
  """
  def forward(remote_name, params, _context) do
    arguments = stringify_keys(params || %{})

    case CraftClient.call_tool(remote_name, arguments, timeout: @default_timeout) do
      {:ok, response} ->
        unwrap_response(response, remote_name)

      {:error, error} ->
        raise RuntimeError,
              "Craft tool #{remote_name} call failed: #{inspect(error)}"
    end
  end

  @doc """
  List the Craft server's tools and register each in the Hermes
  registry. Returns `{:ok, count}` or `{:error, reason}`.
  """
  def register_tools do
    with :ok <- await_client_ready(40) do
      do_register_tools()
    end
  end

  # The Hermes client connects asynchronously: until the initialize
  # handshake completes, operations fail with "Server capabilities
  # not set". Poll the capabilities read until the client is ready.
  defp await_client_ready(0), do: {:error, :craft_client_not_ready}

  defp await_client_ready(attempts) do
    # get_server_info/0 returns nil until the handshake completes.
    if CraftClient.get_server_info() do
      :ok
    else
      Process.sleep(250)
      await_client_ready(attempts - 1)
    end
  end

  defp do_register_tools do
    case CraftClient.list_tools(timeout: @default_timeout) do
      {:ok, %{result: %{"tools" => tools}}} when is_list(tools) ->
        Enum.each(tools, &register_tool/1)
        {:ok, length(tools)}

      {:ok, other} ->
        {:error, {:unexpected_list_tools_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    config = Keyword.merge(craft_config(), opts)

    case ensure_client_started(config) do
      :ok ->
        Process.send_after(self(), :register_tools, @register_delay_ms)
        {:ok, %{config: config, attempts: 0, registered: 0}}

      {:error, reason} ->
        Logger.error("CraftBridge: could not start Craft MCP client: #{inspect(reason)}")
        {:ok, %{config: config, attempts: @max_register_attempts, registered: 0}}
    end
  end

  @impl true
  def handle_info(:register_tools, %{attempts: attempts} = state)
      when attempts >= @max_register_attempts do
    Logger.error(
      "CraftBridge: giving up registering Craft tools after #{attempts} attempts; " <>
        "Craft tools will be unavailable"
    )

    {:noreply, state}
  end

  def handle_info(:register_tools, state) do
    with :ok <- Registry.await_ready(2_000),
         {:ok, count} <- register_tools() do
      Logger.info("CraftBridge: registered #{count} Craft Anything tools")
      {:noreply, %{state | registered: count}}
    else
      other ->
        Logger.warning(
          "CraftBridge: registration attempt #{state.attempts + 1} failed: #{inspect(other)}; retrying"
        )

        Process.send_after(self(), :register_tools, 1_000)
        {:noreply, %{state | attempts: state.attempts + 1}}
    end
  end

  # Private

  defp craft_config do
    Application.get_env(:cybernetic, :craft_mcp, [])
  end

  defp ensure_client_started(config) do
    command = Keyword.get(config, :command, "craft-anything-cli")
    args = Keyword.get(config, :args, ["mcp"])

    # The Hermes client only assembles its full start options
    # (client_info, capabilities, protocol version) in child_spec/1;
    # calling start_link/1 directly crashes the client supervisor
    # with a missing :client_info key. Start through the spec.
    %{start: {mod, fun, start_args}} =
      CraftClient.child_spec(transport: {:stdio, command: command, args: args})

    case apply(mod, fun, start_args) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_tool(%{"name" => remote_name} = tool) do
    Registry.register_tool(
      "craft_" <> remote_name,
      tool["description"] || "",
      tool["inputSchema"] || %{},
      {:forward, __MODULE__, remote_name},
      capabilities: ["craft", "external"],
      metadata: %{source: "craft-anything", remote_name: remote_name}
    )
  end

  defp unwrap_response(response, remote_name) do
    result = Map.get(response, :result) || %{}
    is_error = Map.get(response, :is_error, false) || Map.get(result, "isError", false)

    if is_error do
      raise RuntimeError,
            "Craft tool #{remote_name} returned an error: #{inspect(result)}"
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
