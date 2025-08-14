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
    {:ok, %{amqp_exchange: opts[:exchange] || "cyb.events"}}
  end

  @impl true
  def handle_info({:s4_output, text}, state) do
    case Jason.decode(text) do
      {:ok, %{"sop_updates" => updates} = doc} when is_list(updates) ->
        Enum.each(updates, fn upd ->
          msg =
            Message.normalize(%{
              "headers" => %{"type" => "sop.update", "priority" => "high"},
              "payload" => upd
            })

          publish_sop(msg, state.amqp_exchange)
        end)

        :telemetry.execute([:cybernetic, :sop, :generated], %{count: length(updates)}, %{doc: doc})
      _ ->
        Logger.debug("S4 output not JSON-structured; skipping SOP materialization.")
    end

    {:noreply, state}
  end

  defp publish_sop(msg, ex) do
    # Use existing AMQP publisher
    Publisher.publish(ex, "sop.update", Jason.encode!(msg), persistent: true)
  end
end