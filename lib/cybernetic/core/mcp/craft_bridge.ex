defmodule Cybernetic.Core.MCP.CraftBridge do
  @moduledoc """
  Bridges the external Craft Anything MCP server into the Hermes
  tool registry.

  On start (only when `config :cybernetic, :craft_mcp, enabled: true`)
  the bridge:

    1. starts `Cybernetic.Core.MCP.CraftClient` connected to
       `craft-anything-cli mcp` over stdio,
    2. enables the configured Craft toolsets on the server,
    3. lists the server's tools,
    4. registers each one in `Cybernetic.Core.MCP.Hermes.Registry`
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

  ## Toolsets

  Craft lists only its Essentials (core) toolset at first. Before
  listing tools, the bridge enables the toolsets named in the
  `:toolsets` config (default `["native", "browser"]` — the native
  code and Websites sets). The native set's tools only appear in the
  server's tool list when the server runs in Deep mode, so the
  default launch args are `["--deep", "mcp"]`: Deep mode lets Craft
  read inside study targets, which is the bridge's purpose. Both the
  args and the toolset list are configurable; set `toolsets: []` and
  `args: ["mcp"]` for a clean-room, Essentials-only bridge.

  The connection uses the purpose-built `CraftClient`, not the
  Hermes MCP client: hermes_mcp 0.14.1 drops server messages larger
  than one stdio chunk and wedges after `enable_toolset`, and the
  widened tool list is ~125 KB. See `CraftClient`'s moduledoc.
  """

  use GenServer
  require Logger

  alias Cybernetic.Core.MCP.CraftClient
  alias Cybernetic.Core.MCP.Hermes.Registry

  @default_timeout 30_000
  @default_args ["--deep", "mcp"]
  @default_toolsets ["native", "browser"]
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
      {:ok, result} ->
        unwrap_result(result, remote_name)

      {:error, error} ->
        raise RuntimeError,
              "Craft tool #{remote_name} call failed: #{inspect(error)}"
    end
  end

  @doc """
  Enable the configured toolsets on the Craft server, list its
  tools, and register each in the Hermes registry. Returns
  `{:ok, count}` or `{:error, reason}`.
  """
  def register_tools(config \\ craft_config()) do
    with :ok <- await_client_ready(40) do
      enable_toolsets(Keyword.get(config, :toolsets, @default_toolsets))
      do_register_tools()
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
         {:ok, count} <- register_tools(state.config) do
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
    args = Keyword.get(config, :args, @default_args)

    case CraftClient.start_link(command: command, args: args) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The client connects asynchronously: until the initialize
  # handshake completes, get_server_info/0 returns nil.
  defp await_client_ready(0), do: {:error, :craft_client_not_ready}

  defp await_client_ready(attempts) do
    if CraftClient.get_server_info() do
      :ok
    else
      Process.sleep(250)
      await_client_ready(attempts - 1)
    end
  end

  # Craft only lists the Essentials toolset until others are enabled
  # on the live server. A toolset that fails to enable is logged and
  # skipped — the rest still register.
  defp enable_toolsets(toolsets) do
    Enum.each(toolsets, fn toolset ->
      case CraftClient.call_tool("enable_toolset", %{"toolset" => toolset},
             timeout: @default_timeout
           ) do
        {:ok, _result} ->
          Logger.info("CraftBridge: enabled Craft toolset #{toolset}")

        {:error, error} ->
          Logger.warning("CraftBridge: could not enable toolset #{toolset}: #{inspect(error)}")
      end
    end)
  end

  defp do_register_tools do
    case CraftClient.list_tools(timeout: @default_timeout) do
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
      "craft_" <> remote_name,
      tool["description"] || "",
      tool["inputSchema"] || %{},
      {:forward, __MODULE__, remote_name},
      capabilities: ["craft", "external"],
      metadata: %{source: "craft-anything", remote_name: remote_name}
    )
  end

  defp unwrap_result(result, remote_name) do
    if Map.get(result, "isError", false) do
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
