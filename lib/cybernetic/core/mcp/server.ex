defmodule Cybernetic.Core.MCP.Server do
  @moduledoc """
  Hermes MCP Server compatibility shim.

  > #### Quarantined registration surface {: .warning}
  > This module previously carried a `register_tools/1` that, from
  > `init/2`, registered four tools into
  > `Cybernetic.Core.MCP.Hermes.Registry` with **function-capture
  > handlers** (`&handle_vsm_query/2` etc.). The registry's
  > invocation dispatch only accepts `{module, function}` tuples and
  > `{:forward, module, remote_name}` handlers, so those tools could
  > never be invoked — and three of their names (`vsm_query`,
  > `crdt_merge`, `send_telegram`) collided with the registry's
  > builtins, so if `init/2` had ever run, ETS last-write-wins would
  > have silently replaced working builtins with undispatchable
  > captures.
  >
  > The registration code was removed under Axiomatic Design
  > coupling #9 (Issue #86): the Hermes Registry is the single
  > registration/invocation surface, and tools enter it only through
  > `Registry.register_tool/5` with a dispatchable handler. This
  > shim now registers nothing; `handle_tool/3` remains as a thin
  > delegation to `Registry.invoke_tool/3` for any future Hermes
  > server integration.
  """

  # Note: Uncomment when Hermes.Server is available
  # use Hermes.Server,
  #   name: "Cybernetic aMCP Server",
  #   version: "1.0.0",
  #   capabilities: [:tools]

  alias Cybernetic.Core.MCP.Hermes.Registry

  @doc """
  Compatibility init: accepts the client/frame pair and returns the
  frame unchanged. Registers no tools (see the moduledoc).
  """
  @spec init(term(), term()) :: {:ok, term()}
  def init(_client, frame) do
    {:ok, frame}
  end

  @doc """
  Delegate a tool invocation to the Hermes registry.
  """
  @spec handle_tool(String.t(), map(), term()) ::
          {:ok, term(), term()} | {:error, term(), term()}
  def handle_tool(name, args, frame) do
    case Registry.invoke_tool(name, args) do
      {:ok, result} ->
        {:ok, result, frame}

      {:error, reason} ->
        {:error, reason, frame}
    end
  end
end
