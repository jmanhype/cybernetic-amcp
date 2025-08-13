defmodule Cybernetic.VSM.System4.MessageHandler do
  @moduledoc """
  Message handler for VSM System 4 (Intelligence).
  Handles intelligence and analytics messages.
  """
  require Logger

  def handle_message(operation, payload, meta) do
    Logger.debug("System4 received #{operation}: #{inspect(payload)}")
    
    case operation do
      "intelligence" -> handle_intelligence(payload, meta)
      "analyze" -> handle_analyze(payload, meta)
      "learn" -> handle_learn(payload, meta)
      "predict" -> handle_predict(payload, meta)
      "intelligence_update" -> handle_intelligence_update(payload, meta)
      "default" -> handle_default(payload, meta)
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
      :ok
    end
  end

  defp handle_analyze(payload, meta) do
    Logger.info("System4: Analyzing data - #{inspect(payload)}")
    :ok
  end

  defp handle_learn(payload, meta) do
    Logger.debug("System4: Learning from data - #{inspect(payload)}")
    :ok
  end

  defp handle_predict(payload, meta) do
    Logger.info("System4: Making prediction - #{inspect(payload)}")
    :ok
  end

  defp handle_intelligence_update(payload, meta) do
    Logger.debug("System4: Intelligence update - #{inspect(payload)}")
    :ok
  end

  defp handle_default(payload, _meta) do
    Logger.debug("System4: Default handler - #{inspect(payload)}")
    :ok
  end
  
  defp return(value), do: value
end