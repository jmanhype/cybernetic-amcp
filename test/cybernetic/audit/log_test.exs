defmodule Cybernetic.Audit.LogTest do
  @moduledoc """
  IP-27 special-bar tests: the audit log must prove tamper evidence
  end to end (write entries, flip a byte, verification reports the
  break at the right entry), rotation must anchor each day with a
  Merkle root that recomputes, and the log must survive the
  writer's restart (the record-keeper is not inside the VSM tree).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Cybernetic.Audit.Log

  setup do
    dir = Path.join(System.tmp_dir!(), "audit-log-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp start_log(dir, opts \\ []) do
    {:ok, pid} = Log.start_link([dir: dir] ++ opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp record_n(n, type \\ :test_event) do
    for i <- 1..n, do: Log.record(type, %{n: i})
    # entries_between is a call: it is ordered after our casts.
    Log.entries_between()
  end

  test "appended entries form a verifiable chain", %{dir: dir} do
    start_log(dir)
    entries = record_n(5)

    assert length(entries) == 5
    assert Enum.map(entries, & &1["seq"]) == [1, 2, 3, 4, 5]
    assert hd(entries)["prev_hash"] == "GENESIS"

    for {entry, prev} <- Enum.zip(Enum.drop(entries, 1), entries) do
      assert entry["prev_hash"] == prev["hash"]
    end

    assert Log.head() == {5, List.last(entries)["hash"]}

    file = Path.join(dir, Log.file_name(Date.utc_today()))
    assert {:ok, %{entries: 5, anchors: 0}} = Log.verify_file(file)
    assert {:ok, %{files: 1, entries: 5}} = Log.verify_dir(dir)
  end

  test "tamper evidence: a flipped byte fails verification at the edited entry", %{dir: dir} do
    start_log(dir)
    record_n(3)

    file = Path.join(dir, Log.file_name(Date.utc_today()))
    lines = File.read!(file) |> String.split("\n", trim: true)
    assert length(lines) == 3

    # Flip one payload character in the second entry ("n":2 -> "n":9)
    tampered =
      lines
      |> List.update_at(1, &String.replace(&1, ~s("n":2), ~s("n":9)))
      |> Enum.join("\n")

    File.write!(file, tampered <> "\n")

    assert {:error, %{seq: 2, reason: :hash_mismatch}} = Log.verify_file(file)
    assert {:error, %{seq: 2, reason: :hash_mismatch}} = Log.verify_dir(dir)
  end

  test "tamper evidence: a deleted entry fails verification", %{dir: dir} do
    start_log(dir)
    record_n(3)

    file = Path.join(dir, Log.file_name(Date.utc_today()))
    lines = File.read!(file) |> String.split("\n", trim: true)

    File.write!(file, (List.delete_at(lines, 1) |> Enum.join("\n")) <> "\n")

    assert {:error, %{seq: 3, reason: reason}} = Log.verify_file(file)
    assert reason in [:seq_gap, :prev_hash_mismatch]
  end

  test "tamper evidence: reordered entries fail verification", %{dir: dir} do
    start_log(dir)
    record_n(3)

    file = Path.join(dir, Log.file_name(Date.utc_today()))
    [first, second, third] = File.read!(file) |> String.split("\n", trim: true)

    File.write!(file, Enum.join([second, first, third], "\n") <> "\n")

    assert {:error, %{reason: reason}} = Log.verify_file(file)
    assert reason in [:seq_gap, :prev_hash_mismatch]
  end

  test "day rotation closes the previous day with a verifiable Merkle anchor", %{dir: dir} do
    # Dates are relative to the real today: verify_dir exempts only
    # the current day's file from the anchor requirement.
    today = Date.utc_today()
    yesterday = Date.add(today, -1)
    day1_start = DateTime.new!(yesterday, ~T[23:59:00], "Etc/UTC")
    day2_start = DateTime.new!(today, ~T[00:01:00], "Etc/UTC")

    {:ok, clock_pid} = Agent.start_link(fn -> day1_start end)
    clock = fn -> Agent.get(clock_pid, & &1) end
    start_log(dir, clock: clock)

    day1_entries = record_n(3)
    day1_hashes = Enum.map(day1_entries, & &1["hash"])

    Agent.update(clock_pid, fn _ -> day2_start end)
    record_n(1)

    day1_file = Path.join(dir, Log.file_name(yesterday))
    day1_lines = File.read!(day1_file) |> String.split("\n", trim: true)
    assert length(day1_lines) == 4

    anchor = day1_lines |> List.last() |> Jason.decode!()
    assert anchor["type"] == "daily_anchor"
    assert anchor["payload"]["date"] == Date.to_string(yesterday)
    assert anchor["payload"]["entries"] == 3
    assert anchor["payload"]["merkle_root"] == Log.merkle_root(day1_hashes)

    # Yesterday is past and anchored; the chain links across the
    # file boundary through the anchor.
    assert {:ok, %{entries: 5, anchors: 1}} = Log.verify_dir(dir)
  end

  test "restart recovery: a fresh log process resumes the chain from disk", %{dir: dir} do
    pid = start_log(dir)
    record_n(2)
    GenServer.stop(pid)

    start_log(dir)
    entries = record_n(1)

    assert Enum.map(entries, & &1["seq"]) == [1, 2, 3]
    assert {:ok, %{entries: 3}} = Log.verify_dir(dir)
  end

  test "writer isolation: the log's chain survives a ControlSupervisor restart", %{dir: dir} do
    start_log(dir)

    cs_pid =
      case Cybernetic.VSM.System3.ControlSupervisor.start_link() do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    Cybernetic.VSM.System3.ControlSupervisor.report_algedonic(:pain, 0.5, "test")
    assert [%{"type" => "algedonic_signal"}] = wait_for_entries(1)

    GenServer.stop(cs_pid)
    {:ok, _new_pid} = Cybernetic.VSM.System3.ControlSupervisor.start_link()

    Cybernetic.VSM.System3.ControlSupervisor.report_algedonic(:pleasure, 0.4, "test")
    entries = wait_for_entries(2)

    assert Enum.map(entries, & &1["seq"]) == [1, 2]
    assert {:ok, %{entries: 2}} = Log.verify_dir(dir)
  end

  # report_algedonic is a cast to the ControlSupervisor, which then
  # casts to the log: cross-process casts are not ordered against
  # this test's calls, so poll briefly.
  defp wait_for_entries(expected, attempts \\ 50) do
    entries = Log.entries_between()

    cond do
      length(entries) >= expected ->
        entries

      attempts <= 0 ->
        flunk("expected #{expected} audit entries, got #{length(entries)}")

      true ->
        Process.sleep(20)
        wait_for_entries(expected, attempts - 1)
    end
  end

  test "record/2 is a safe no-op when the log is not running" do
    assert Process.whereis(Log) == nil
    assert :ok = Log.record(:anything, %{x: 1})
    assert Log.entries_between() == []
    assert Log.head() == nil
    assert Log.verify_chain() == {:error, :not_running}
  end

  test "mix cyb.audit_verify passes a clean directory and fails a tampered one", %{dir: dir} do
    start_log(dir)
    record_n(2)

    output =
      capture_io(fn ->
        assert :ok = Mix.Tasks.Cyb.AuditVerify.run(["--dir", dir])
      end)

    assert output =~ "OK"

    file = Path.join(dir, Log.file_name(Date.utc_today()))
    lines = File.read!(file) |> String.split("\n", trim: true)

    tampered =
      lines
      |> List.update_at(0, &String.replace(&1, ~s("n":1), ~s("n":7)))
      |> Enum.join("\n")

    File.write!(file, tampered <> "\n")

    assert_raise Mix.Error, fn ->
      capture_io(fn -> Mix.Tasks.Cyb.AuditVerify.run(["--dir", dir]) end)
    end
  end
end
