defmodule Cybernetic.VSM.System3.AlgedonicProducerIdentityTest do
  @moduledoc """
  Phase 2 amendment (WC G2 pull-forward): the dedup bar with
  REAL producer-minted identities, end to end - not
  hand-injected ids.

  Before the amendment, this branch's dedup evidence was
  synthetic: no producer minted an identity (TelemetryAlgedonic
  minted in branch 3's scope; S1's emit_algedonic_signal/2 was
  assigned to no branch), so the same emission arriving by two
  paths carried two different ids - or none - and dedup could
  never fire for it. Both minting sites are now branch-1 work:

  - TelemetryAlgedonic mints once per emission; the id rides
    the AMQP payload and the in-process report alike. The test
    drives the plugin's own telemetry handler into a severe
    pain emission, reads the minted id back from the audit
    log's :algedonic_signal entry, then delivers the s3 AMQP
    copy of that same emission through process_vsm_message/2:
    exactly one signal and one duplicate, origin
    :goldrush_telemetry.
  - S1's emit_algedonic_signal/2 mints into the published
    payload. The test drives five error operations through
    System1.MessageHandler (its real threshold path), captures
    the published signal from the InMemory transport's test
    collector, and forwards it through S4 twice - a delivery
    and its redelivery: counted once, one duplicate via :s4,
    origin :s1 preserved.

  Note on driving TelemetryAlgedonic in this branch's tree:
  its telemetry attach still carries the wildcard names that
  can never fire (branch 3 replaces them), so the test calls
  the plugin's own handler function - the exact function the
  attach registers - rather than emitting telemetry nothing
  would receive. The emission path from there (window,
  severity routing, minting, report) is the production code.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Audit.Log
  alias Cybernetic.Core.Goldrush.Plugins.TelemetryAlgedonic
  alias Cybernetic.Transport.InMemory
  alias Cybernetic.VSM.System1.MessageHandler, as: S1Handler
  alias Cybernetic.VSM.System3.ControlSupervisor
  alias Cybernetic.VSM.System4.MessageHandler

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "algedonic-producer-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    {:ok, log_pid} = Log.start_link(dir: dir)
    cs_pid = fresh(ControlSupervisor)

    on_exit(fn ->
      InMemory.set_test_collector(nil)
      if Process.alive?(cs_pid), do: GenServer.stop(cs_pid)
      if Process.alive?(log_pid), do: GenServer.stop(log_pid)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp fresh(module) do
    case Process.whereis(module) do
      nil ->
        {:ok, pid} = module.start_link([])
        pid

      existing ->
        GenServer.stop(existing)
        {:ok, pid} = module.start_link([])
        pid
    end
  end

  defp feed_plugin(event, count) do
    for _ <- 1..count do
      TelemetryAlgedonic.handle_telemetry_event(event, %{}, %{}, nil)
    end

    :sys.get_state(TelemetryAlgedonic)
    :ok
  end

  defp entries(type) do
    Log.entries_between() |> Enum.filter(&(&1["type"] == type))
  end

  defp await_with_id(type, id, attempts \\ 100) do
    found =
      entries(type)
      |> Enum.filter(&(&1["payload"]["signal_id"] == id))

    if found != [] or attempts == 0 do
      found
    else
      Process.sleep(20)
      await_with_id(type, id, attempts - 1)
    end
  end

  test "TelemetryAlgedonic's severe emission and its AMQP copy dedup on the producer-minted id" do
    fresh(TelemetryAlgedonic)

    # Drive the window to severe pain: 8 errors then 2 successes
    # passes the rate through 1/9 = 0.111 (severe, 0.85). The
    # plugin in this branch's state emits per event (gating is
    # branch 3), so several emissions occur; the test follows
    # the severe one specifically.
    feed_plugin([:amqp, :message, :error], 8)
    feed_plugin([:amqp, :message, :processed], 2)
    :sys.get_state(ControlSupervisor)

    severe =
      entries("algedonic_signal")
      |> Enum.filter(&(&1["payload"]["intensity"] == 0.85))

    assert length(severe) == 1
    id = hd(severe)["payload"]["signal_id"]
    assert is_binary(id)
    assert hd(severe)["payload"]["source"] == "goldrush_telemetry"

    # The s3 AMQP copy of that same emission, as the consumer
    # would dispatch it (the payload the plugin published,
    # carrying the minted id).
    assert :ok =
             ControlSupervisor.process_vsm_message(
               %{
                 "type" => "algedonic.pain",
                 "severity" => "severe",
                 "signal_id" => id,
                 "metrics" => %{}
               },
               "s3.algedonic.pain.severe"
             )

    # Still exactly one signal with this id; the copy is a
    # duplicate via :amqp, origin preserved.
    assert length(await_with_id("algedonic_signal", id)) == 1

    duplicates = await_with_id("algedonic_duplicate", id)
    assert length(duplicates) == 1
    assert hd(duplicates)["payload"]["via"] == "amqp"
    assert hd(duplicates)["payload"]["origin"] == "goldrush_telemetry"

    buffered =
      ControlSupervisor.get_status().recent_algedonic
      |> Enum.filter(&(&1.signal_id == id))

    assert length(buffered) == 1
  end

  test "S1's published signal carries a minted id; S4 delivery and redelivery dedup on it" do
    # S1's record_algedonic_event/3 skips recording entirely
    # while :test_mode is set ("to prevent feedback loops" in
    # the test env generally). This test is precisely about the
    # recording path, so it lifts the guard for its own
    # duration and restores it after; the module is async:
    # false and the env is put back in on_exit.
    Application.put_env(:cybernetic, :test_mode, false)
    on_exit(fn -> Application.put_env(:cybernetic, :test_mode, true) end)

    InMemory.set_test_collector(self())

    # Five error operations cross S1's pain threshold (>= 5
    # errors in 10 s) and emit through the real publish path.
    for _ <- 1..5 do
      assert :ok = S1Handler.handle_message("error", %{"severity" => "high"}, %{})
    end

    assert_received {:system4_message, signal}
    assert signal["source_system"] == "s1"
    assert signal["type"] == "algedonic.pain"
    id = signal["signal_id"]
    assert is_binary(id)

    # Delivery through the S4 forward, then the same message
    # redelivered: the forward preserves the minted id and the
    # origin, and the second arrival is a duplicate.
    assert :ok = MessageHandler.handle_message("algedonic", signal, %{})
    assert :ok = MessageHandler.handle_message("algedonic", signal, %{})

    status = ControlSupervisor.get_status()
    assert status.metrics.algedonic_signals == 1
    assert [%{source: :s1, signal_id: ^id}] = status.recent_algedonic

    assert length(await_with_id("algedonic_signal", id)) == 1

    duplicates = await_with_id("algedonic_duplicate", id)
    assert length(duplicates) == 1
    assert hd(duplicates)["payload"]["via"] == "s4"
    assert hd(duplicates)["payload"]["origin"] == "s1"
  end
end
