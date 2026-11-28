defmodule Cybernetic.Core.Goldrush.TelemetryWindowTest do
  @moduledoc """
  Phase 2 (§5.2) window bars for TelemetryAlgedonic:

  - Food: the plugin attaches to the exact message-outcome names
    the consumer seams produce (branch 2 of this phase) - before,
    its attach list was wildcard segments that could never fire
    and its counted names had no producer anywhere in lib/.
  - Transition gating: holding the window in a trigger zone
    emits nothing further; each level change emits exactly once;
    recovery rearms the gate so re-entry emits again. On the
    pre-phase code the hold assertions fail by construction
    (emission ran on every event while in a zone).
  - Single path: reports arrive through report_algedonic with
    origin :goldrush_telemetry and a minted signal id each, and
    S3's metric count equals the audit log's signal count.

  The early events in an empty window swing the success rate
  across zones transiently, so the gating assertions are made on
  deltas after the window settles into a zone, with monotone
  event streams that cross exactly one level boundary per stage.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Audit.Log
  alias Cybernetic.Core.Goldrush.Plugins.TelemetryAlgedonic
  alias Cybernetic.VSM.System3.ControlSupervisor

  @processed [:amqp, :message, :processed]
  @error [:amqp, :message, :error]

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "telemetry-window-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    {:ok, log_pid} = Log.start_link(dir: dir)

    fresh(ControlSupervisor)
    fresh(TelemetryAlgedonic)

    on_exit(fn ->
      if Process.alive?(log_pid), do: GenServer.stop(log_pid)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # Starts a fresh instance of a named GenServer (stopping any
  # instance an earlier suite left running), so window and signal
  # counters start empty and the counts below are deterministic.
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

  defp emit(name, count) do
    for _ <- 1..count, do: :telemetry.execute(name, %{}, %{})

    # Flush: get_state returns only after every cast the telemetry
    # handlers sent has been handled by the window process.
    :sys.get_state(TelemetryAlgedonic)
    :ok
  end

  # Emits (failures, successes) groups - the interleaving the
  # staged rates below are computed against.
  defp emit_mix(failures, successes, groups) do
    for _ <- 1..groups do
      emit(@error, failures)
      emit(@processed, successes)
    end
  end

  defp signal_entries do
    Log.entries_between()
    |> Enum.filter(&(&1["type"] == "algedonic_signal"))
  end

  defp await_signals(count, attempts \\ 100) do
    entries = signal_entries()

    if length(entries) >= count or attempts == 0 do
      entries
    else
      Process.sleep(20)
      await_signals(count, attempts - 1)
    end
  end

  # The settled view of the audit log: ControlSupervisor is
  # flushed (every report the window sent has been handled, and
  # its audit casts sent), then the entry count must be stable
  # across two reads 50 ms apart - no emission is still in flight.
  defp signals_now(previous_count \\ -1) do
    :sys.get_state(ControlSupervisor)
    entries = signal_entries()

    if length(entries) == previous_count do
      entries
    else
      Process.sleep(50)
      signals_now(length(entries))
    end
  end

  defp last_intensity(entries), do: List.last(entries)["payload"]["intensity"]

  test "the window attaches to exact names with real producers - no wildcards" do
    for event <- [@processed, @error, [:amqp, :message, :replay]] do
      ids = :telemetry.list_handlers(event) |> Enum.map(& &1.id)
      assert "telemetry-algedonic" in ids
    end
  end

  test "transition gating: hold emits nothing, each level change emits once, recovery rearms" do
    # Settle into pain :moderate - 50 successes, 150 failures
    # (rate 0.25), interleaved so the window ends in the zone.
    emit_mix(3, 1, 50)

    settled = signals_now()
    assert last_intensity(settled) == 0.75
    assert List.last(settled)["payload"]["source"] == "goldrush_telemetry"
    settled_count = length(settled)

    # Hold the zone (rate stays within 0.24-0.26): no new report.
    # Pre-phase code emitted once per event here.
    emit_mix(3, 1, 5)
    assert length(signals_now()) == settled_count

    # Escalate to :severe - 100 more failures (rate 55/320 =
    # 0.172), crossing only the 0.2 boundary: exactly one report.
    emit(@error, 100)
    entries = await_signals(settled_count + 1)
    assert length(signals_now()) == settled_count + 1
    assert last_intensity(entries) == 0.85

    # Escalate to :critical - 300 more failures (rate 55/620 =
    # 0.089), crossing only the 0.1 boundary: exactly one report.
    emit(@error, 300)
    entries = await_signals(settled_count + 2)
    assert length(signals_now()) == settled_count + 2
    assert last_intensity(entries) == 0.95

    # Recover to neutral - 200 successes (rate 255/820 = 0.311).
    # The climb re-enters :severe then :moderate (one report
    # each), then leaves the pain zone entirely.
    emit(@processed, 200)
    entries = await_signals(settled_count + 4)
    assert length(signals_now()) == settled_count + 4

    # Hold neutral (interleaved pairs, rate stays ~0.31): nothing.
    emit_mix(1, 1, 10)
    assert length(signals_now()) == settled_count + 4

    # Re-enter pain - 300 failures (rate 255/1120 = 0.228,
    # :moderate). The rearmed gate emits again: exactly one.
    emit(@error, 300)
    entries = await_signals(settled_count + 5)
    assert length(signals_now()) == settled_count + 5
    assert last_intensity(entries) == 0.75

    # S3's metric count equals the audit log's signal count, and
    # every report carried its own minted identity.
    assert ControlSupervisor.get_status().metrics.algedonic_signals ==
             settled_count + 5

    ids = Enum.map(entries, & &1["payload"]["signal_id"])
    assert Enum.all?(ids, &is_binary/1)
    assert length(Enum.uniq(ids)) == length(ids)
  end

  test "pleasure zone: a near-perfect window reports :high once and holds it" do
    emit(@processed, 100)
    emit(@error, 3)

    # Rate settles at 100/103 = 0.971 -> pleasure :high (0.85).
    settled = signals_now()
    last = List.last(settled)
    assert last["payload"]["signal_type"] == "pleasure"
    assert last["payload"]["intensity"] == 0.85
    settled_count = length(settled)

    # More of the same (rate rises to 150/153 = 0.980, still
    # :high): no re-emission.
    emit(@processed, 50)
    assert length(signals_now()) == settled_count
  end
end
