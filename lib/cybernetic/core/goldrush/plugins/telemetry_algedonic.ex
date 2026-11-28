defmodule Cybernetic.Core.Goldrush.Plugins.TelemetryAlgedonic do
  @moduledoc """
  Goldrush plugin that converts telemetry events into algedonic signals.
  Implements pain/pleasure signals for VSM S4 (Intelligence) based on system health.
  """
  @behaviour Cybernetic.Core.Plugins.Behaviour

  use GenServer
  require Logger

  # Phase 2 (§5.2): exact event names only. :telemetry matches
  # names exactly, so the wildcard segments this list used to
  # carry ([:cybernetic, :*], [:amqp, :message, :*], [:vsm, :*, :*],
  # [:telegram, :*, :*]) could never fire - the attach was
  # decoration. These three names are exactly the ones
  # update_metrics/2 counts, and they have real producers at the
  # consumer dispatch seams (Phase 2, §6).
  @telemetry_events [
    [:amqp, :message, :processed],
    [:amqp, :message, :error],
    [:amqp, :message, :replay]
  ]

  # Error rate above this triggers pain signal
  @pain_threshold 0.3
  # Success rate above this triggers pleasure signal
  @pleasure_threshold 0.95
  # 1 minute sliding window
  @window_size 60_000

  defmodule State do
    defstruct [
      :window_start,
      events: [],
      metrics: %{
        success: 0,
        failure: 0,
        latency_sum: 0,
        latency_count: 0
      },
      algedonic_state: :neutral,
      # Transition gating (Phase 2, §5.2): the last {kind, level}
      # actually emitted, or :none. Sitting in a trigger zone does
      # not re-emit; only a change does.
      last_emitted: :none
    ]
  end

  # Plugin Behaviour Implementation

  @impl true
  def init_plugin(opts) do
    {:ok, opts}
  end

  @impl true
  def activate(config) do
    {:ok, _pid} = start_link(config)
    :ok
  end

  @impl true
  def deactivate(_config) do
    GenServer.stop(__MODULE__)
  end

  @impl true
  def info do
    %{
      name: "Telemetry Algedonic",
      version: "1.0.0",
      description: "Converts telemetry into VSM algedonic signals",
      capabilities: ["telemetry", "algedonic", "vsm", "goldrush"]
    }
  end

  # GenServer Implementation

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    # Attach to telemetry events
    :telemetry.attach_many(
      "telemetry-algedonic",
      @telemetry_events,
      &__MODULE__.handle_telemetry_event/4,
      nil
    )

    # Schedule window cleanup
    Process.send_after(self(), :cleanup_window, @window_size)

    {:ok, %State{window_start: System.monotonic_time(:millisecond)}}
  end

  # Telemetry Handler

  def handle_telemetry_event(event_name, measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:telemetry_event, event_name, measurements, metadata})
  end

  # Callbacks

  @impl GenServer
  def handle_cast({:telemetry_event, event_name, measurements, metadata}, state) do
    event = %{
      name: event_name,
      measurements: measurements,
      metadata: metadata,
      timestamp: System.monotonic_time(:millisecond)
    }

    new_state =
      state
      |> add_event(event)
      |> update_metrics(event)
      |> check_algedonic_triggers()

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:cleanup_window, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @window_size

    # Remove old events
    filtered_events =
      Enum.filter(state.events, fn event ->
        event.timestamp > cutoff
      end)

    # Recalculate metrics
    new_state =
      %State{
        window_start: cutoff,
        events: filtered_events,
        metrics: recalculate_metrics(filtered_events),
        algedonic_state: state.algedonic_state,
        last_emitted: state.last_emitted
      }
      |> check_algedonic_triggers()

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_window, @window_size)

    {:noreply, new_state}
  end

  # Canonical Addressing

  @doc """
  Build the canonical algedonic routing key for a target system.

  The canonical addressing scheme (coupling #6) routes inter-system
  VSM traffic with `sN.<channel>` keys on the `cyb.commands`
  exchange. Algedonic signals keep their full shape under the
  system's prefix: `algedonic_routing_key("s3", :pain, :severe)`
  is `"s3.algedonic.pain.severe"`. A `nil` level omits the suffix:
  `algedonic_routing_key("s4", :pain, nil)` is `"s4.algedonic.pain"`.

  Retained as the canonical key builder (pinned by the addressing
  scheme tests) even though this plugin no longer publishes:
  since Phase 2 (§5.2) its signals travel the in-process report
  path only. If a future cross-node deployment restores an AMQP
  path for Goldrush signals, this is the key shape it must use -
  with §7's signal identity making the round-trip safe.
  """
  @spec algedonic_routing_key(String.t(), :pain | :pleasure, atom() | nil) :: String.t()
  def algedonic_routing_key(system, kind, nil), do: "#{system}.algedonic.#{kind}"

  def algedonic_routing_key(system, kind, level),
    do: "#{system}.algedonic.#{kind}.#{level}"

  # Private Functions

  defp add_event(state, event) do
    %{state | events: [event | state.events]}
  end

  defp update_metrics(state, event) do
    metrics = state.metrics

    # Update based on event type
    metrics =
      case event.name do
        [:amqp, :message, :processed] ->
          Map.update!(metrics, :success, &(&1 + 1))

        [:amqp, :message, :error] ->
          Map.update!(metrics, :failure, &(&1 + 1))

        [:amqp, :message, :replay] ->
          Map.update!(metrics, :failure, &(&1 + 1))

        _ ->
          metrics
      end

    # Update latency if present
    metrics =
      if latency = event.measurements[:duration] || event.measurements[:latency] do
        metrics
        |> Map.update!(:latency_sum, &(&1 + latency))
        |> Map.update!(:latency_count, &(&1 + 1))
      else
        metrics
      end

    %{state | metrics: metrics}
  end

  defp check_algedonic_triggers(state) do
    total = state.metrics.success + state.metrics.failure

    if total > 0 do
      success_rate = state.metrics.success / total

      avg_latency =
        if state.metrics.latency_count > 0 do
          state.metrics.latency_sum / state.metrics.latency_count
        else
          0
        end

      {new_algedonic_state, emission} =
        cond do
          success_rate < @pain_threshold ->
            {:pain, {:pain, calculate_pain_severity(success_rate)}}

          success_rate > @pleasure_threshold ->
            {:pleasure, {:pleasure, calculate_pleasure_intensity(success_rate)}}

          true ->
            {:neutral, :none}
        end

      state = maybe_emit(state, emission, success_rate, avg_latency)

      if new_algedonic_state != state.algedonic_state do
        Logger.info("Algedonic state changed: #{state.algedonic_state} -> #{new_algedonic_state}")
      end

      %{state | algedonic_state: new_algedonic_state}
    else
      state
    end
  end

  # Transition gating (Phase 2, §5.2): a signal is emitted only
  # when the computed {kind, level} differs from the last emitted
  # one. Entering a zone, escalating within it (moderate ->
  # severe -> critical), and recovering out of it are the
  # transitions; sitting in a zone, however many events arrive,
  # emits nothing further. Returning to neutral rearms the gate,
  # so a later re-entry emits again. Before this phase the check
  # emitted on every event while the window sat in a zone - one
  # pain episode became one signal per message.
  defp maybe_emit(state, :none, _success_rate, _avg_latency) do
    %{state | last_emitted: :none}
  end

  defp maybe_emit(%{last_emitted: emission} = state, emission, _success_rate, _avg_latency) do
    state
  end

  defp maybe_emit(state, {:pain, severity}, success_rate, avg_latency) do
    emit_pain_signal(success_rate, avg_latency, state.metrics, severity)
    %{state | last_emitted: {:pain, severity}}
  end

  defp maybe_emit(state, {:pleasure, intensity}, success_rate, avg_latency) do
    emit_pleasure_signal(success_rate, avg_latency, state.metrics, intensity)
    %{state | last_emitted: {:pleasure, intensity}}
  end

  defp emit_pain_signal(success_rate, avg_latency, metrics, severity) do
    signal = %{
      type: "algedonic.pain",
      severity: severity,
      success_rate: success_rate,
      avg_latency: avg_latency,
      metrics: metrics,
      timestamp: DateTime.utc_now(),
      recommendations: generate_pain_recommendations(success_rate, avg_latency)
    }

    Logger.warning(
      "PAIN signal (#{severity}): success_rate=#{success_rate}, reporting to S3 Control"
    )

    # Emit telemetry event (observed by tests and the probe)
    :telemetry.execute(
      [:goldrush, :algedonic, :pain],
      %{severity: signal.severity, success_rate: success_rate},
      signal
    )

    # Single-path emission (Phase 2, §5.2): the in-process report
    # to S3's ControlSupervisor - coupling #3's single entry
    # point - is the only path a Goldrush window signal takes.
    # The AMQP publishes that used to fan this signal out to the
    # s3/s4/s5 queues are removed. Corrected census (WC H1/G1,
    # ruled 2026-11-28): the fan-out's worst case was a 2x count
    # at the entry point - severe pain only (in-process report
    # plus the s3 copy); the severity routing was mutually
    # exclusive, the S4 consumer never dispatched Goldrush
    # algedonic from its envelope, and as shipped the producer
    # never emitted at all, so the shipped count was 0. The s5
    # (critical) copy also landed on a handler with no algedonic
    # clause and errored. One path, stated accurately.
    # S3 is the actor; Phase 1's audit log is how the rest of the
    # system reads what the reflex layer did.
    report_to_control(:pain, severity)
  end

  defp emit_pleasure_signal(success_rate, avg_latency, metrics, intensity) do
    signal = %{
      type: "algedonic.pleasure",
      intensity: intensity,
      success_rate: success_rate,
      avg_latency: avg_latency,
      metrics: metrics,
      timestamp: DateTime.utc_now(),
      recommendations: generate_pleasure_recommendations(success_rate, avg_latency)
    }

    Logger.info(
      "PLEASURE signal (#{intensity}): success_rate=#{success_rate}, reporting to S3 Control"
    )

    # Emit telemetry event (observed by tests and the probe)
    :telemetry.execute(
      [:goldrush, :algedonic, :pleasure],
      %{intensity: signal.intensity, success_rate: success_rate},
      signal
    )

    # Single-path emission (see emit_pain_signal).
    report_to_control(:pleasure, intensity)
  end

  # The algedonic intensity scale shared with
  # Cybernetic.VSM.System4.MessageHandler: ControlSupervisor
  # processes pain above 0.7 and auto-intervenes above 0.8.
  defp report_to_control(type, level) do
    if Process.whereis(Cybernetic.VSM.System3.ControlSupervisor) do
      intensity =
        case level do
          :critical -> 0.95
          :euphoric -> 0.95
          :severe -> 0.85
          :high -> 0.85
          :moderate -> 0.75
          _other -> 0.5
        end

      # Phase 2 (§7): each window emission mints its signal id at
      # this, its first-emission point; the origin is this plugin.
      Cybernetic.VSM.System3.ControlSupervisor.report_algedonic(
        type,
        intensity,
        :goldrush_telemetry,
        Cybernetic.VSM.System3.ControlSupervisor.mint_signal_id()
      )
    end

    :ok
  end

  defp calculate_pain_severity(success_rate) do
    cond do
      success_rate < 0.1 -> :critical
      success_rate < 0.2 -> :severe
      success_rate < 0.3 -> :moderate
      true -> :mild
    end
  end

  defp calculate_pleasure_intensity(success_rate) do
    cond do
      success_rate > 0.99 -> :euphoric
      success_rate > 0.97 -> :high
      success_rate > 0.95 -> :moderate
      true -> :mild
    end
  end

  defp generate_pain_recommendations(success_rate, avg_latency) do
    recommendations = []

    recommendations =
      if success_rate < 0.5 do
        ["Investigate message processing failures" | recommendations]
      else
        recommendations
      end

    recommendations =
      if avg_latency > 1000 do
        ["Optimize message processing latency" | recommendations]
      else
        recommendations
      end

    if recommendations == [] do
      ["Monitor system health metrics closely"]
    else
      recommendations
    end
  end

  defp generate_pleasure_recommendations(_success_rate, _avg_latency) do
    [
      "System performing optimally",
      "Consider increasing throughput capacity",
      "Document current configuration for future reference"
    ]
  end

  defp recalculate_metrics(events) do
    Enum.reduce(events, %{success: 0, failure: 0, latency_sum: 0, latency_count: 0}, fn event,
                                                                                        acc ->
      acc =
        case event.name do
          [:amqp, :message, :processed] -> Map.update!(acc, :success, &(&1 + 1))
          [:amqp, :message, :error] -> Map.update!(acc, :failure, &(&1 + 1))
          [:amqp, :message, :replay] -> Map.update!(acc, :failure, &(&1 + 1))
          _ -> acc
        end

      if latency = event.measurements[:duration] || event.measurements[:latency] do
        acc
        |> Map.update!(:latency_sum, &(&1 + latency))
        |> Map.update!(:latency_count, &(&1 + 1))
      else
        acc
      end
    end)
  end
end
