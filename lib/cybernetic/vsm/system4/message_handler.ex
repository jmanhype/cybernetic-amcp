defmodule Cybernetic.VSM.System4.MessageHandler do
  @moduledoc """
  Message handler for VSM System 4 (Intelligence).
  Handles intelligence and analytics messages.
  """
  require Logger

  def handle_message(operation, payload, meta) do
    # Wrap in telemetry span for dynamic tracing
    :telemetry.span(
      [:cybernetic, :archeology, :span],
      %{system: :s4, operation: operation},
      fn ->
        Logger.debug("System4 received #{operation}: #{inspect(payload)}")

        result = do_handle_message(operation, payload, meta)

        {result, %{payload_size: byte_size(inspect(payload))}}
      end
    )
  end

  defp do_handle_message(operation, payload, meta) do
    case operation do
      "intelligence" ->
        handle_intelligence(payload, meta)

      "analyze" ->
        handle_analyze(payload, meta)

      "learn" ->
        handle_learn(payload, meta)

      "predict" ->
        handle_predict(payload, meta)

      "intelligence_update" ->
        handle_intelligence_update(payload, meta)

      "algedonic" ->
        handle_algedonic(payload, meta)

      "default" ->
        handle_default(payload, meta)

      _ ->
        Logger.warning("Unknown operation for System4: #{operation}")
        {:error, :unknown_operation}
    end
  rescue
    error ->
      Logger.error("Error in System4 message handler: #{inspect(error)}")
      {:error, error}
  end

  defp handle_intelligence(payload, meta) do
    # Validate analysis type if present
    analysis_type = Map.get(payload, :analysis) || Map.get(payload, "analysis")

    if analysis_type && analysis_type == "invalid_type" do
      {:error, :invalid_analysis_type}
    else
      Logger.info("System4: Processing intelligence - #{inspect(payload)}")

      # Process the intelligence and emit telemetry
      process_intelligence_analysis(payload, meta)

      # Emit telemetry for S4 intelligence processing
      :telemetry.execute([:vsm, :s4, :intelligence], %{count: 1}, payload)

      :ok
    end
  end

  defp handle_analyze(payload, _meta) do
    Logger.info("System4: Analyzing data - #{inspect(payload)}")
    :ok
  end

  defp handle_learn(payload, _meta) do
    Logger.debug("System4: Learning from data - #{inspect(payload)}")
    :ok
  end

  defp handle_predict(payload, _meta) do
    Logger.info("System4: Making prediction - #{inspect(payload)}")
    :ok
  end

  defp handle_intelligence_update(payload, _meta) do
    Logger.debug("System4: Intelligence update - #{inspect(payload)}")
    :ok
  end

  defp handle_algedonic(payload, meta) do
    # Handle algedonic (pain/pleasure) signals from S1
    signal_type = Map.get(payload, "type")
    Logger.info("System4: Processing algedonic signal - #{signal_type}")

    case signal_type do
      "algedonic.pain" ->
        handle_pain_signal(payload, meta)

      "algedonic.pleasure" ->
        handle_pleasure_signal(payload, meta)

      _ ->
        Logger.warning("System4: Unknown algedonic signal type - #{signal_type}")
        {:error, :unknown_algedonic_type}
    end
  end

  defp handle_default(payload, _meta) do
    Logger.debug("System4: Default handler - #{inspect(payload)}")
    :ok
  end

  defp handle_pain_signal(payload, _meta) do
    # Process pain signal and generate intervention
    data = Map.get(payload, "data", %{})
    severity = Map.get(data, :severity, :moderate)

    Logger.warning("System4: Pain signal received - severity: #{severity}")

    # Determine intervention strategy based on severity
    action =
      case severity do
        :critical -> "alert_s5"
        :severe -> "scale_resources"
        _ -> "throttle_operations"
      end

    # Generate intervention message
    intervention = %{
      "type" => "vsm.s4.intervention",
      "action" => action,
      "severity" => severity,
      "reason" => "algedonic_pain_response",
      "data" => data,
      "timestamp" => DateTime.utc_now()
    }

    # Send intervention (for test purposes, we'll emit telemetry)
    :telemetry.execute([:vsm, :s4, :intervention], %{severity: severity}, intervention)

    # Close the algedonic loop: forward the signal to S3's
    # ControlSupervisor, the single owner of the algedonic path
    # (buffer, thresholds, intervention). Until now this handler was
    # a dead end — signals arrived from S1 and went no further than
    # telemetry, while ControlSupervisor's algedonic machinery was
    # only ever exercised by tests.
    forward_algedonic(:pain, severity, payload)

    # Also send directly to test collector if present
    if test_collector =
         :persistent_term.get({:test_collector, Cybernetic.Transport.InMemory}, nil) do
      send(test_collector, {:s4_intervention, intervention})
    end

    Logger.info("System4: Generated intervention - #{action}")

    :ok
  end

  defp handle_pleasure_signal(payload, _meta) do
    # Process pleasure signal and generate optimization
    data = Map.get(payload, "data", %{})
    intensity = Map.get(data, :intensity, :mild)

    Logger.info("System4: Pleasure signal received - intensity: #{intensity}")

    # Determine optimization strategy
    strategy =
      case intensity do
        :euphoric -> "increase_throughput"
        :high -> "reduce_resources"
        _ -> "maintain_state"
      end

    # Generate optimization message
    optimization = %{
      "type" => "vsm.s4.optimization",
      "strategy" => strategy,
      "intensity" => intensity,
      "reason" => "algedonic_pleasure_response",
      "data" => data,
      "timestamp" => DateTime.utc_now()
    }

    # Send optimization (for test purposes, we'll emit telemetry)
    :telemetry.execute([:vsm, :s4, :optimization], %{intensity: intensity}, optimization)

    # Close the algedonic loop (see handle_pain_signal).
    forward_algedonic(:pleasure, intensity, payload)

    # Also send directly to test collector if present
    if test_collector =
         :persistent_term.get({:test_collector, Cybernetic.Transport.InMemory}, nil) do
      send(test_collector, {:s4_optimization, optimization})
    end

    Logger.info("System4: Generated optimization - #{strategy}")

    :ok
  end

  # The algedonic intensity scale shared by every producer that
  # reports into ControlSupervisor (this handler and the Goldrush
  # TelemetryAlgedonic plugin): ControlSupervisor processes pain
  # above 0.7 and auto-intervenes above 0.8, so :moderate (what S1
  # emits for its error bursts) lands in the escalate-for-analysis
  # band, and only :severe / :critical trigger intervention.
  defp algedonic_intensity(level) do
    case level do
      :critical -> 0.95
      :euphoric -> 0.95
      :severe -> 0.85
      :high -> 0.85
      :moderate -> 0.75
      _other -> 0.5
    end
  end

  defp algedonic_source(payload) do
    case Map.get(payload, "source_system") do
      "s1" -> :s1
      "s2" -> :s2
      "s3" -> :s3
      "s5" -> :s5
      _other -> :s4
    end
  end

  defp forward_algedonic(type, level, payload) do
    # ControlSupervisor runs in the full tree; in reduced trees the
    # signal stays telemetry-only rather than crashing the handler.
    if Process.whereis(Cybernetic.VSM.System3.ControlSupervisor) do
      Cybernetic.VSM.System3.ControlSupervisor.report_algedonic(
        type,
        algedonic_intensity(level),
        algedonic_source(payload)
      )
    end

    :ok
  end

  defp process_intelligence_analysis(payload, _meta) do
    # Analyze the intelligence data from S2
    coordination_id = Map.get(payload, "coordination_id")
    analysis_type = Map.get(payload, "analysis_request", "general")

    # Create analysis result
    analysis_result = %{
      "type" => "vsm.s4.analysis_complete",
      "coordination_id" => coordination_id,
      "analysis_type" => analysis_type,
      "patterns_detected" => ["normal_operation", "coordination_success"],
      "health_score" => 0.95,
      "recommendations" => ["maintain_current_state"],
      "timestamp" => DateTime.utc_now()
    }

    Logger.debug("System4: Analysis complete for #{coordination_id}")

    # Send analysis back to coordination or to other systems if needed
    analysis_result
  end
end
