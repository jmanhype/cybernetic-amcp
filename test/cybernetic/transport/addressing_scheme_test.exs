defmodule Cybernetic.Transport.AddressingSchemeTest do
  @moduledoc """
  Stage-1 coupling #6 verification: one canonical addressing scheme
  (`sN.<channel>` keys on `cyb.commands`), one topology declaration
  site, and pattern routing in the InMemory transport.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Core.Goldrush.Plugins.TelemetryAlgedonic
  alias Cybernetic.Core.Transport.AMQP.Topology
  alias Cybernetic.Transport.InMemory

  @canonical_bindings %{
    "cyb.s1.ops" => "s1.#",
    "cyb.s2.coord" => "s2.#",
    "cyb.s3.control" => "s3.#",
    "cyb.s4.llm" => "s4.#",
    "cyb.s5.policy" => "s5.#"
  }

  describe "InMemory pattern routing" do
    setup do
      InMemory.set_test_collector(self())
      on_exit(fn -> InMemory.set_test_collector(nil) end)
      :ok
    end

    test "delivers every canonical key shape to the addressed system" do
      message = %{"type" => "addressing_probe"}

      expectations = [
        # literal handler keys
        {"s2.coordinate", :system2_message},
        {"s4.intelligence", :system4_message},
        {"s4.algedonic", :system4_message},
        {"s3.control", :system3_message},
        {"s5.policy", :system5_message},
        # constructed coordination key (System2 MessageHandler A4 shape)
        {"s1.coordination", :system1_message},
        # response keys
        {"s2.sync_response", :system2_message},
        {"s2.status_response", :system2_message},
        {"s1.resource_response", :system1_message},
        # multi-segment algedonic key (Goldrush canonical shape)
        {"s3.algedonic.pain.severe", :system3_message},
        # telegram classifier keys
        {"s1.echo", :system1_message},
        {"s4.reason", :system4_message}
      ]

      for {key, tag} <- expectations do
        assert :ok = InMemory.publish("cyb.commands", key, message, [])
        assert_receive {^tag, ^message}, 500
      end
    end

    test "keys outside the canonical scheme are still rejected" do
      assert {:error, :unknown_routing_key} =
               InMemory.publish("cyb.commands", "vsm.s1.operations", %{}, [])

      assert {:error, :unknown_routing_key} =
               InMemory.publish("cyb.events", "retry.100", %{}, [])

      assert {:error, :unknown_routing_key} =
               InMemory.publish("cyb.commands", "s9.coordinate", %{}, [])

      assert {:error, :unknown_routing_key} =
               InMemory.publish("cyb.commands", "s2", %{}, [])
    end
  end

  describe "consolidated topology (as data)" do
    test "declares the canonical VSM queues and no retired vsm.* queues" do
      queue_names = Enum.map(Topology.queues(), fn {name, _opts} -> name end)

      for queue <- Map.keys(@canonical_bindings) do
        assert queue in queue_names
      end

      refute Enum.any?(queue_names, &String.starts_with?(&1, "vsm."))
    end

    test "binds each canonical queue on cyb.commands with its sN.# pattern" do
      bindings = Topology.bindings()

      for {queue, pattern} <- @canonical_bindings do
        assert {"cyb.commands", queue, pattern} in bindings
      end

      # No binding may reference a retired queue or a retired
      # per-system exchange.
      refute Enum.any?(bindings, fn {_exchange, queue, _key} ->
               String.starts_with?(queue, "vsm.")
             end)

      refute Enum.any?(bindings, fn {exchange, _queue, _key} ->
               String.starts_with?(exchange, "cyb.vsm.")
             end)
    end

    test "non-VSM topology is intact" do
      queue_names = Enum.map(Topology.queues(), fn {name, _opts} -> name end)

      for queue <- [
            "telemetry.metrics",
            "telemetry.logs",
            "cyb.telemetry.q",
            "events.stream",
            "priority.alerts",
            "dlq",
            "cyb.events.retry",
            "cyb.events.failed"
          ] do
        assert queue in queue_names
      end

      bindings = Topology.bindings()
      assert {"cyb.telemetry", "telemetry.metrics", "metrics.#"} in bindings
      assert {"cyb.events", "events.stream", "#"} in bindings
      assert {"vsm.dlx", "dlq", ""} in bindings
    end

    test "queue_for_system/1 returns canonical queue names" do
      assert Topology.queue_for_system(1) == "cyb.s1.ops"
      assert Topology.queue_for_system(2) == "cyb.s2.coord"
      assert Topology.queue_for_system(3) == "cyb.s3.control"
      assert Topology.queue_for_system(4) == "cyb.s4.llm"
      assert Topology.queue_for_system(5) == "cyb.s5.policy"
    end

    test "runtime config no longer feeds queues to the Connection" do
      amqp_config = Application.get_env(:cybernetic, :amqp, [])
      assert Keyword.get(amqp_config, :queues) == nil

      exchanges = Keyword.get(amqp_config, :exchanges, %{})
      refute Map.has_key?(exchanges, :s1)
      assert Map.get(exchanges, :commands) == "cyb.commands"
    end
  end

  describe "Goldrush algedonic key translation" do
    test "builds canonical sN.algedonic keys" do
      assert TelemetryAlgedonic.algedonic_routing_key("s5", :pain, :critical) ==
               "s5.algedonic.pain.critical"

      assert TelemetryAlgedonic.algedonic_routing_key("s3", :pain, :severe) ==
               "s3.algedonic.pain.severe"

      assert TelemetryAlgedonic.algedonic_routing_key("s4", :pain, nil) ==
               "s4.algedonic.pain"

      assert TelemetryAlgedonic.algedonic_routing_key("s5", :pleasure, :euphoric) ==
               "s5.algedonic.pleasure.euphoric"

      assert TelemetryAlgedonic.algedonic_routing_key("s4", :pleasure, :high) ==
               "s4.algedonic.pleasure.high"

      assert TelemetryAlgedonic.algedonic_routing_key("s5", :pleasure, :high) ==
               "s5.algedonic.pleasure.high"

      assert TelemetryAlgedonic.algedonic_routing_key("s4", :pleasure, nil) ==
               "s4.algedonic.pleasure"
    end
  end
end
