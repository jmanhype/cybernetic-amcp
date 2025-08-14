defmodule Cybernetic.Core.Aggregator.CentralAggregator do
  @moduledoc """
  Collects events (telemetry & Goldrush matches), maintains a rolling window,
  and periodically emits condensed facts for S4.

  Emits: [:cybernetic, :aggregator, :facts] with %{facts: [...]}, meta: %{window: "..."}
  """
  use GenServer
  require Logger

  @table :cyb_agg_window
  @emit_every_ms 5_000
  @window_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Ensure table exists or create it
    case :ets.whereis(@table) do
      :undefined -> 
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      _ -> 
        # Table already exists, clear it
        :ets.delete_all_objects(@table)
    end
    
    attach_sources()
    Process.send_after(self(), :emit, @emit_every_ms)
    {:ok, %{last_emit: now_ms()}}
  end

  defp attach_sources do
    # Detach any existing handlers first
    :telemetry.detach({__MODULE__, :goldrush})
    
    # Goldrush matches → [:cybernetic, :goldrush, :match]
    result = :telemetry.attach_many(
      {__MODULE__, :goldrush},
      [[:cybernetic, :goldrush, :match], [:cybernetic, :work, :finished], [:cybernetic, :work, :failed]],
      &__MODULE__.handle_source/4,
      %{}
    )
    
    case result do
      :ok -> Logger.info("CentralAggregator telemetry handlers attached")
      {:error, reason} -> Logger.warning("Failed to attach CentralAggregator handlers: #{inspect(reason)}")
    end
  end

  @doc false
  def handle_source(event, meas, meta, _cfg) do
    entry = %{
      at: System.system_time(:millisecond),
      source: event,
      severity: meta[:severity] || "info",
      labels: meta[:labels] || %{},
      data: meas
    }

    :ets.insert(@table, {entry.at, entry})
  end

  @impl true
  def handle_info(:emit, state), do: {:noreply, do_emit(state)}

  @impl true
  def handle_continue(:emit, state), do: {:noreply, do_emit(state)}

  @impl true
  def handle_cast(:tick, state), do: {:noreply, do_emit(state)}

  defp do_emit(state) do
    prune()
    facts = summarize()
    :telemetry.execute([:cybernetic, :aggregator, :facts], %{facts: facts}, %{window: "60s"})
    Process.send_after(self(), :emit, @emit_every_ms)
    %{state | last_emit: now_ms()}
  end

  defp prune do
    case :ets.whereis(@table) do
      :undefined -> 
        Logger.warning("CentralAggregator: ETS table #{@table} not found during prune")
        :ok
      _ ->
        cutoff = now_ms() - @window_ms
        # Simple approach: delete all entries older than cutoff
        # In production, use ordered_set with efficient range deletion
        all_keys = :ets.select(@table, [{{:"$1", :_}, [{:<, :"$1", cutoff}], [:"$1"]}])
        Enum.each(all_keys, &:ets.delete(@table, &1))
    end
  end

  defp summarize do
    case :ets.whereis(@table) do
      :undefined -> 
        Logger.warning("CentralAggregator: ETS table #{@table} not found during summarize")
        []
      _ ->
        :ets.tab2list(@table)
        |> Enum.map(fn {_k, v} -> v end)
        |> to_facts()
    end
  end

  defp to_facts(entries) do
    # Example rollup: counts by label and severity
    by_label =
      entries
      |> Enum.group_by(fn e -> {e.source, e.severity, e.labels} end)
      |> Enum.map(fn {{src, sev, labels}, group} ->
        %{
          "source" => Enum.join(Enum.map(src, &inspect/1), "/"),
          "severity" => sev,
          "labels" => labels,
          "count" => length(group)
        }
      end)

    by_label
  end

  defp now_ms, do: System.system_time(:millisecond)
end