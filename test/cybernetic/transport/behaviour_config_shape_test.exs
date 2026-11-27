defmodule Cybernetic.Transport.BehaviourConfigShapeTest do
  @moduledoc """
  Coupling #8 verification: the `:transport` config is canonically a
  bare module implementing `Cybernetic.Transport.Behaviour`.

  The old keyword-list shape in config.exs (adapter / max_demand /
  nested amqp options) had no readers in lib/ and survived only
  because runtime.exs / test.exs overwrote it later in config load
  order. `current_transport/0` now fails fast on any non-module
  shape instead of crashing obscurely on the first publish.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Transport.Behaviour

  test "configured transport is a bare module (config-shape regression)" do
    transport = Application.get_env(:cybernetic, :transport)

    assert is_atom(transport),
           "expected :transport to be a bare module, got: #{inspect(transport)}"
  end

  test "current_transport/0 returns the configured module in test env" do
    assert Behaviour.current_transport() == Cybernetic.Transport.InMemory
  end

  test "keyword-list transport config raises a clear error" do
    previous = Application.get_env(:cybernetic, :transport)

    Application.put_env(:cybernetic, :transport,
      adapter: Cybernetic.Transport.AMQP,
      max_demand: 1000
    )

    try do
      assert_raise ArgumentError, ~r/invalid :transport configuration/, fn ->
        Behaviour.current_transport()
      end

      assert_raise ArgumentError, ~r/invalid :transport configuration/, fn ->
        Behaviour.publish("cyb.commands", "s2.coordinate", %{"type" => "ping"})
      end
    after
      if previous do
        Application.put_env(:cybernetic, :transport, previous)
      else
        Application.delete_env(:cybernetic, :transport)
      end
    end
  end
end
