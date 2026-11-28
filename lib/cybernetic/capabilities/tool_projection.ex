defmodule Cybernetic.Capabilities.ToolProjection do
  @moduledoc """
  One-way projection from the Hermes MCP tool registry into the
  Capabilities registry (Axiomatic Design coupling #9, Issue #86).

  ## Division of labor

  `Cybernetic.Core.MCP.Hermes.Registry` is the source of truth for
  MCP tool *registration and invocation*. `Cybernetic.Capabilities.Registry`
  owns *discovery* — semantic search — but before this module
  existed nothing ever registered into it, so `discover/1` searched
  an empty set and could never find a tool that actually exists.

  This GenServer bridges the two, in one direction only:

    * **Catch-up** — on start (and whenever Hermes signals
      readiness again), it enumerates `Hermes.Registry.list_tools/0`
      and mirrors every tool into the Capabilities registry.
    * **Event-driven** — it subscribes to the
      `[:cybernetic, :mcp_registry, :tool_registered]` telemetry
      event Hermes emits on every registration, and projects each
      new tool as it arrives (this is how `craft_*` tools, which
      register after boot, become discoverable).

  Each projected record carries the tool's name and description, an
  embedding computed via `Cybernetic.Intelligence.Embeddings` from
  name + description + capability tags (so semantic `discover/1`
  actually finds it), `provider: Cybernetic.Core.MCP.Hermes.Registry`
  (the invoking registry — the Capabilities registry itself never
  invokes), and metadata marking it as a projection:
  `%{mcp_tool: name, source: :hermes | :craft, projected_from: :hermes_registry}`.

  ## Guarantees

    * **One-way.** The projection never writes into Hermes and
      never invokes a tool. Hermes state is byte-identical before
      and after a projection run.
    * **Idempotent.** Re-running catch-up refreshes each projected
      record in place, via a single atomic replace inside the
      Capabilities registry: exactly one capability record per
      tool name, never a duplicate, and a concurrent reader never
      observes the name missing mid-refresh. A name already owned
      by a *manually* registered (non-projection) capability is
      skipped and logged, never overwritten.
    * **Self-healing resync.** Catch-up also prunes projection-owned
      records whose tools have vanished from Hermes. Because the
      Hermes readiness event re-triggers catch-up, a Hermes registry
      restart (which re-registers its builtins) is healed on the
      Capabilities side without restarting this process. Note the
      Hermes-side caveat is unchanged: `craft_*` tools themselves
      only re-enter Hermes if the Craft bridge re-registers them.
    * **Degrades to idle.** If the Hermes registry (or the
      Capabilities registry) is not running — e.g. the minimal test
      tree, where the Capabilities supervisor never starts — the
      projection retries catch-up a bounded number of times and
      then simply idles on the telemetry subscription. It never
      crash-loops its supervisor.
  """

  use GenServer

  require Logger

  alias Cybernetic.Capabilities.Registry, as: CapabilitiesRegistry
  alias Cybernetic.Core.MCP.Hermes.Registry, as: HermesRegistry
  alias Cybernetic.Core.MCP.Hermes.Registry.Tool
  alias Cybernetic.Intelligence.Embeddings

  @tool_registered_event [:cybernetic, :mcp_registry, :tool_registered]
  @ready_event [:cybernetic, :mcp_registry, :ready]
  @catch_up_delay_ms 200
  @catch_up_retry_ms 500
  @max_catch_up_attempts 30

  # Client API

  @doc "Start the projection GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Synchronously re-run the catch-up projection: mirror every tool
  currently in the Hermes registry into the Capabilities registry
  and prune projection-owned records whose tools have vanished.

  Returns `{:ok, count}` with the number of Hermes tools seen, or
  `{:error, reason}` when either registry is unavailable.
  """
  @spec resync() :: {:ok, non_neg_integer()} | {:error, term()}
  def resync do
    GenServer.call(__MODULE__, :resync, 120_000)
  end

  @doc false
  def handle_telemetry_event(@tool_registered_event, _measurements, %{tool: %Tool{} = tool}, pid) do
    send(pid, {:hermes_tool_registered, tool})
  end

  def handle_telemetry_event(@ready_event, _measurements, _metadata, pid) do
    send(pid, :hermes_ready)
  end

  def handle_telemetry_event(_event, _measurements, _metadata, _pid), do: :ok

  # Server callbacks

  @impl true
  def init(_opts) do
    handler_id = {:tool_projection, self()}

    case :telemetry.attach_many(
           handler_id,
           [@tool_registered_event, @ready_event],
           &__MODULE__.handle_telemetry_event/4,
           self()
         ) do
      :ok ->
        :ok

      {:error, :already_exists} ->
        Logger.warning(
          "ToolProjection: telemetry handler #{inspect(handler_id)} already attached; continuing"
        )
    end

    Process.send_after(self(), :catch_up, @catch_up_delay_ms)

    {:ok, %{handler_id: handler_id, attempts: 0}}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  @impl true
  def handle_call(:resync, _from, state) do
    {:reply, do_resync(), state}
  end

  @impl true
  def handle_info({:hermes_tool_registered, %Tool{} = tool}, state) do
    project_tool(tool)
    {:noreply, state}
  end

  def handle_info(:hermes_ready, state) do
    # Hermes (re)registered its builtins: resync heals the
    # projection after a Hermes restart.
    Process.send_after(self(), :catch_up, 100)
    {:noreply, %{state | attempts: 0}}
  end

  def handle_info(:catch_up, state) do
    case do_resync() do
      {:ok, count} when count > 0 ->
        {:noreply, %{state | attempts: 0}}

      _other ->
        # Hermes not up yet (or still empty): retry a bounded
        # number of times, then idle on the telemetry
        # subscription — never crash-loop the supervisor.
        if state.attempts < @max_catch_up_attempts do
          Process.send_after(self(), :catch_up, @catch_up_retry_ms)
          {:noreply, %{state | attempts: state.attempts + 1}}
        else
          Logger.info(
            "ToolProjection: Hermes registry not available after " <>
              "#{@max_catch_up_attempts} attempts; idling until the next registration event"
          )

          {:noreply, state}
        end
    end
  end

  # Projection internals

  @spec do_resync() :: {:ok, non_neg_integer()} | {:error, term()}
  defp do_resync do
    cond do
      not is_pid(Process.whereis(HermesRegistry)) ->
        {:error, :hermes_unavailable}

      not is_pid(Process.whereis(CapabilitiesRegistry)) ->
        {:error, :capabilities_unavailable}

      true ->
        case safe_list_tools() do
          {:ok, tools} ->
            Enum.each(tools, &project_tool/1)
            prune_stale(tools)
            {:ok, length(tools)}

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp safe_list_tools do
    HermesRegistry.list_tools()
  catch
    :exit, _ -> {:error, :hermes_unavailable}
  end

  @spec project_tool(Tool.t()) :: :ok | :skipped | {:error, term()}
  defp project_tool(%Tool{} = tool) do
    # Build the record (including the embedding) BEFORE touching
    # the Capabilities registry, so no registry mutation is ever
    # separated from its replacement by a slow provider call.
    attrs = capability_attrs(tool)

    case safe_get_by_name(tool.name) do
      {:ok, existing} ->
        if projection?(existing) do
          # Refresh in place: one atomic replace inside the
          # Capabilities registry, so a concurrent list/0 or
          # discover/2 always sees either the old record or the
          # new one — never a torn set with the name missing.
          replace_projection(existing, tool, attrs)
        else
          Logger.warning(
            "ToolProjection: skipping #{inspect(tool.name)} — a non-projection " <>
              "capability already owns that name"
          )

          :skipped
        end

      {:error, :not_found} ->
        register_projection(tool, attrs)

      {:error, _reason} = error ->
        error
    end
  catch
    :exit, _ -> {:error, :registry_unavailable}
  end

  @spec replace_projection(CapabilitiesRegistry.capability(), Tool.t(), map()) ::
          :ok | :skipped | {:error, term()}
  defp replace_projection(existing, tool, attrs) do
    case CapabilitiesRegistry.replace(existing.id, attrs) do
      {:ok, _capability} ->
        :ok

      {:error, :not_found} ->
        # The record vanished between the lookup and the replace
        # (e.g. pruned concurrently): fall back to a fresh insert.
        register_projection(tool, attrs)

      {:error, reason} = error ->
        Logger.warning(
          "ToolProjection: could not refresh #{inspect(tool.name)}: #{inspect(reason)}"
        )

        error
    end
  end

  defp safe_get_by_name(name) do
    CapabilitiesRegistry.get_by_name(name)
  catch
    :exit, _ -> {:error, :capabilities_unavailable}
  end

  @spec register_projection(Tool.t(), map()) :: :ok | :skipped | {:error, term()}
  defp register_projection(%Tool{} = tool, attrs) do
    case CapabilitiesRegistry.register(attrs) do
      {:ok, _capability} ->
        :ok

      {:error, :name_already_registered} ->
        # Lost a race with a manual registration between the check
        # and the insert: the manual record wins, we skip.
        Logger.warning(
          "ToolProjection: skipping #{inspect(tool.name)} — name registered concurrently"
        )

        :skipped

      {:error, reason} = error ->
        Logger.warning(
          "ToolProjection: could not project #{inspect(tool.name)}: #{inspect(reason)}"
        )

        error
    end
  end

  @spec capability_attrs(Tool.t()) :: map()
  defp capability_attrs(%Tool{} = tool) do
    embedding =
      case Embeddings.embed(embedding_text(tool)) do
        {:ok, vector} ->
          vector

        {:error, reason} ->
          Logger.warning(
            "ToolProjection: embedding failed for #{inspect(tool.name)} " <>
              "(#{inspect(reason)}); projecting without an embedding — " <>
              "the record is listed but semantic discover will skip it until a resync succeeds"
          )

          nil
      end

    %{
      name: tool.name,
      description: tool.description || "",
      provider: HermesRegistry,
      inputs: [],
      outputs: [],
      embedding: embedding,
      metadata: %{
        mcp_tool: tool.name,
        source: source_for(tool),
        projected_from: :hermes_registry,
        tool_capabilities: tool.capabilities || []
      }
    }
  end

  @spec embedding_text(Tool.t()) :: String.t()
  defp embedding_text(%Tool{} = tool) do
    "#{tool.name} #{tool.description || ""} #{Enum.join(tool.capabilities || [], " ")}"
    |> String.trim()
  end

  @spec source_for(Tool.t()) :: :hermes | :craft
  defp source_for(%Tool{} = tool) do
    metadata = tool.metadata || %{}

    if metadata[:source] == "craft-anything" or metadata["source"] == "craft-anything" or
         String.starts_with?(tool.name, "craft_") do
      :craft
    else
      :hermes
    end
  end

  @spec projection?(CapabilitiesRegistry.capability()) :: boolean()
  defp projection?(capability) do
    capability.provider == HermesRegistry and
      is_map(capability.metadata) and
      Map.has_key?(capability.metadata, :mcp_tool)
  end

  @spec prune_stale([Tool.t()]) :: :ok
  defp prune_stale(tools) do
    live_names = MapSet.new(tools, & &1.name)

    CapabilitiesRegistry.list()
    |> Enum.filter(&projection?/1)
    |> Enum.reject(&MapSet.member?(live_names, &1.name))
    |> Enum.each(fn capability ->
      Logger.info(
        "ToolProjection: pruning stale projection #{inspect(capability.name)} " <>
          "(no longer in the Hermes registry)"
      )

      CapabilitiesRegistry.unregister(capability.id)
    end)

    :ok
  catch
    :exit, _ -> :ok
  end
end
