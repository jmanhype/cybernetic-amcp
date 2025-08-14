defmodule Cybernetic.Intelligence.S4.SOPEngine do
  @moduledoc """
  Parses S4 analysis JSON → emits SOP notes/policies and publishes to AMQP/VSM.
  """
  use GenServer
  require Logger

  alias Cybernetic.Transport.Message
  alias Cybernetic.Core.Transport.AMQP.Publisher

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    # Schedule periodic SOP review
    schedule_review()
    
    {:ok, %{
      amqp_exchange: opts[:exchange] || "cyb.events",
      active_sops: %{},
      pending_sops: [],
      sop_history: []
    }}
  end

  @impl true
  def handle_info({:s4_output, text}, state) do
    case Jason.decode(text) do
      {:ok, %{"sop_updates" => updates, "risk_score" => risk_score} = doc} when is_list(updates) ->
        new_state = process_sop_updates(updates, risk_score, doc, state)
        :telemetry.execute([:cybernetic, :sop, :generated], %{count: length(updates)}, %{doc: doc})
        {:noreply, new_state}
        
      {:ok, %{"sop_updates" => updates} = doc} when is_list(updates) ->
        # No risk score, use default
        new_state = process_sop_updates(updates, 50, doc, state)
        :telemetry.execute([:cybernetic, :sop, :generated], %{count: length(updates)}, %{doc: doc})
        {:noreply, new_state}
        
      _ ->
        Logger.debug("S4 output not JSON-structured; skipping SOP materialization.")
        {:noreply, state}
    end
  end
  
  @impl true
  def handle_info(:review_sops, state) do
    # Review and activate pending SOPs
    {activated, pending} = review_pending_sops(state.pending_sops)
    
    # Activate SOPs
    Enum.each(activated, fn sop ->
      publish_sop(sop, state.amqp_exchange)
    end)
    
    # Update active SOPs
    new_active = Map.merge(state.active_sops, Map.new(activated, fn sop -> {sop.id, sop} end))
    
    # Schedule next review
    schedule_review()
    
    {:noreply, %{state | active_sops: new_active, pending_sops: pending}}
  end

  defp publish_sop(sop, ex) when is_map(sop) do
    msg = Message.normalize(%{
      "headers" => %{
        "type" => "sop.update",
        "priority" => sop[:priority] || sop["priority"] || "medium",
        "sop_id" => sop[:id] || sop["id"]
      },
      "payload" => sop
    })
    
    # Use existing AMQP publisher
    if Process.whereis(Publisher) do
      Publisher.publish(ex, "s5.policy.update", Jason.encode!(msg), persistent: true)
    end
    
    # Also emit telemetry
    :telemetry.execute(
      [:cybernetic, :s5, :policy, :update],
      %{sop_count: 1},
      %{sop: sop}
    )
    
    Logger.info("Published SOP: #{inspect(sop[:action] || sop["action"])} (priority: #{sop[:priority] || sop["priority"]})")
  end
  
  defp process_sop_updates(updates, risk_score, _doc, state) do
    timestamp = System.system_time(:millisecond)
    
    new_sops = Enum.map(updates, fn update ->
      %{
        id: "sop_#{timestamp}_#{:rand.uniform(9999)}",
        action: update["action"],
        description: update["description"] || update["action"],
        priority: update["priority"] || priority_from_risk(risk_score),
        risk_score: risk_score,
        created_at: timestamp,
        status: :pending,
        metadata: update["metadata"] || %{}
      }
    end)
    
    # Critical SOPs activate immediately
    {immediate, pending} = Enum.split_with(new_sops, fn sop ->
      sop.priority == "critical" || (sop.priority == "high" && risk_score > 75)
    end)
    
    # Publish immediate SOPs
    Enum.each(immediate, fn sop ->
      activated = %{sop | status: :active}
      publish_sop(activated, state.amqp_exchange)
    end)
    
    %{state |
      pending_sops: state.pending_sops ++ pending,
      sop_history: [{timestamp, risk_score, length(updates)} | Enum.take(state.sop_history, 99)]
    }
  end
  
  defp review_pending_sops(pending_sops) do
    now = System.system_time(:millisecond)
    review_period = 60_000  # 1 minute
    
    Enum.split_with(pending_sops, fn sop ->
      (now - sop.created_at) > review_period || sop.priority == "high"
    end)
  end
  
  defp priority_from_risk(risk) when risk >= 80, do: "critical"
  defp priority_from_risk(risk) when risk >= 60, do: "high"
  defp priority_from_risk(risk) when risk >= 40, do: "medium"
  defp priority_from_risk(_), do: "low"
  
  defp schedule_review do
    Process.send_after(self(), :review_sops, 30_000)  # Every 30 seconds
  end
end