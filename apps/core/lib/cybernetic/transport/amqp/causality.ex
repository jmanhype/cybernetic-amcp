defmodule Cybernetic.Transport.AMQP.Causality do
  @moduledoc """
  Causal ordering helpers (Lamport/vector clock propagation).
  """

  def enrich(payload, clock) do
    Map.merge(payload, %{
      lamport: (clock[:lamport] || 0) + 1,
      site: node()
    })
  end
end
