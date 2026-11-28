defmodule Cybernetic.VSM.System3.AlgedonicIdentityTest do
  @moduledoc """
  Phase 2 (§7) signal-integrity bar: one physical algedonic signal
  must reach ControlSupervisor's accounting exactly once, however
  many paths it travels.

  Corrected census (WC review H1/G1, ruled 2026-11-28 - this
  replaces the design's original "up to three times" claim,
  which was wrong): the maximum double-count reachable in the
  pre-phase code was 2x, for severe pain only (the in-process
  report plus the s3 AMQP copy), in a hypothetically fed system;
  as shipped the count was 0, because the producer's wildcard
  attaches could never fire. The severity routing is mutually
  exclusive (severe -> s3 only, critical -> s5 only,
  moderate/mild -> s4 only), and the S4 consumer never dispatches
  Goldrush algedonic from its envelope, so the S4-forward arm
  never carried Goldrush signals at all; it is live for
  S1-originated signals over the InMemory transport. The S4
  forward also overwrote provenance to :s4 for payloads lacking
  "source_system".

  These tests drive one signal down the identity contract's
  paths (in-process report, S4 forward, S3 AMQP dispatch) and
  assert one buffered signal, one metric increment, one
  :algedonic_signal audit entry, and two :algedonic_duplicate
  entries naming the redundant paths. The producer-driven
  end-to-end bar - real minted identities from the real
  producers - is algedonic_producer_identity_test.exs (WC G2
  pull-forward).
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Audit.Log
  alias Cybernetic.VSM.System3.ControlSupervisor
  alias Cybernetic.VSM.System4.MessageHandler

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "algedonic-identity-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    {:ok, log_pid} = Log.start_link(dir: dir)

    # A fresh ControlSupervisor, so its algedonic counter and dedup
    # window start empty and the counts below are deterministic.
    cs_pid =
      case Process.whereis(ControlSupervisor) do
        nil ->
          {:ok, pid} = ControlSupervisor.start_link()
          pid

        existing ->
          GenServer.stop(existing)
          {:ok, pid} = ControlSupervisor.start_link()
          pid
      end

    on_exit(fn ->
      for pid <- [cs_pid, log_pid] do
        if Process.alive?(pid), do: GenServer.stop(pid)
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # Audit writes are casts from ControlSupervisor to the log; poll
  # briefly for the expected entries instead of sleeping blindly.
  defp await_entries(type, count, attempts \\ 50) do
    entries =
      Log.entries_between()
      |> Enum.filter(&(&1["type"] == type))

    if length(entries) >= count or attempts == 0 do
      entries
    else
      Process.sleep(20)
      await_entries(type, count, attempts - 1)
    end
  end

  defp signals_with_id(id) do
    ControlSupervisor.get_status().recent_algedonic
    |> Enum.filter(&(&1.signal_id == id))
  end

  test "one signal via in-process report, S4 forward, and AMQP dispatch is counted once" do
    id = ControlSupervisor.mint_signal_id()

    # Path 1: the origin's in-process report, identity attached.
    ControlSupervisor.report_algedonic(:pain, 0.5, :s1, id)

    # Path 2: S4 forwards the same signal (its AMQP copy). The
    # payload carries the id and the origin's provenance.
    payload = %{
      "type" => "algedonic.pain",
      "source_system" => "s1",
      "signal_id" => id,
      "data" => %{"severity" => :moderate}
    }

    assert :ok = MessageHandler.handle_message("algedonic", payload, %{})

    # Path 3: the S3 AMQP round-trip copy, dispatched with the id.
    assert :ok =
             ControlSupervisor.process_vsm_message(
               %{
                 "type" => "algedonic.pain",
                 "intensity" => 0.5,
                 "source_system" => "s1",
                 "signal_id" => id
               },
               "s3.algedonic.pain"
             )

    status = ControlSupervisor.get_status()

    # Counted once, buffered once, origin preserved (not :s4).
    assert status.metrics.algedonic_signals == 1
    assert [%{source: :s1, signal_id: ^id}] = signals_with_id(id)

    # Audit: one signal entry, two duplicate entries naming the
    # redundant paths (via :s4 for the forward, :amqp for dispatch).
    signal_entries = await_entries("algedonic_signal", 1)
    assert length(signal_entries) == 1
    assert hd(signal_entries)["payload"]["signal_id"] == id
    assert hd(signal_entries)["payload"]["source"] == "s1"

    duplicate_entries = await_entries("algedonic_duplicate", 2)
    assert length(duplicate_entries) == 2

    assert Enum.all?(duplicate_entries, fn entry ->
             entry["payload"]["signal_id"] == id and entry["payload"]["origin"] == "s1"
           end)

    vias = duplicate_entries |> Enum.map(& &1["payload"]["via"]) |> Enum.sort()
    assert vias == ["amqp", "s4"]
  end

  test "distinct ids are distinct signals; id-less reports each mint a fresh id" do
    id_a = ControlSupervisor.mint_signal_id()
    id_b = ControlSupervisor.mint_signal_id()

    ControlSupervisor.report_algedonic(:pain, 0.5, :s1, id_a)
    ControlSupervisor.report_algedonic(:pain, 0.5, :s1, id_b)
    ControlSupervisor.report_algedonic(:pleasure, 0.5, :goldrush_telemetry)
    ControlSupervisor.report_algedonic(:pleasure, 0.5, :goldrush_telemetry)

    status = ControlSupervisor.get_status()
    assert status.metrics.algedonic_signals == 4
    assert length(await_entries("algedonic_signal", 4)) == 4
    assert await_entries("algedonic_duplicate", 0) == []
  end

  test "an unprovenanced payload forwarded by S4 keeps origin :unknown, never :s4" do
    payload = %{
      "type" => "algedonic.pain",
      "data" => %{"severity" => :mild}
    }

    assert :ok = MessageHandler.handle_message("algedonic", payload, %{})

    status = ControlSupervisor.get_status()
    assert status.metrics.algedonic_signals == 1
    assert [%{source: :unknown}] = status.recent_algedonic

    signal_entries = await_entries("algedonic_signal", 1)
    assert hd(signal_entries)["payload"]["source"] == "unknown"
  end

  test "AMQP dispatch mints an identity for id-less payloads" do
    # Goldrush-shaped payload: metrics and no source, no id.
    assert :ok =
             ControlSupervisor.process_vsm_message(
               %{"type" => "algedonic.pain", "severity" => "severe", "metrics" => %{}},
               "s3.algedonic.pain.severe"
             )

    status = ControlSupervisor.get_status()
    assert [%{source: :goldrush_telemetry, signal_id: signal_id}] = status.recent_algedonic
    assert is_binary(signal_id)

    signal_entries = await_entries("algedonic_signal", 1)
    assert hd(signal_entries)["payload"]["signal_id"] == signal_id
    assert hd(signal_entries)["payload"]["source"] == "goldrush_telemetry"
  end
end
