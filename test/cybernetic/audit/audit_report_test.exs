defmodule Cybernetic.Audit.AuditReportTest do
  @moduledoc """
  IP-27 special-bar tests: the rebuilt S3* audit report's numbers
  must be traceable to the audit log. Perform a known set of S3
  actions, then the report counts must match the log exactly - and
  after the log file is tampered with, the report must stop
  claiming compliance.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Audit.Log
  alias Cybernetic.VSM.System3.{ControlSupervisor, RateLimiter}

  setup do
    dir = Path.join(System.tmp_dir!(), "audit-report-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:ok, log_pid} = Log.start_link(dir: dir)

    # A dedicated RateLimiter instance with a 1-token budget, so
    # the second request is a witnessed denial.
    {:ok, rl_pid} =
      RateLimiter.start_link(
        name: AuditReportTestRateLimiter,
        default_budgets: %{audit_test_budget: %{limit: 1, window_ms: 300_000}}
      )

    # A fresh ControlSupervisor, so its algedonic counter starts at
    # zero and the report's reconciliation check is deterministic.
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
      for pid <- [cs_pid, rl_pid, log_pid] do
        if Process.alive?(pid), do: GenServer.stop(pid)
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "report counts match the log after known S3 actions", %{dir: dir} do
    from = DateTime.add(DateTime.utc_now(), -60, :second)

    # Known actions: 2 algedonic signals (below the auto-intervention
    # threshold), 1 manual restart intervention on a dummy process,
    # 1 budget denial (second request against a 1-token budget).
    ControlSupervisor.report_algedonic(:pain, 0.5, "test_source")
    ControlSupervisor.report_algedonic(:pleasure, 0.4, "test_source")

    dummy = spawn(fn -> Process.sleep(10_000) end)

    assert {:ok, _id} =
             ControlSupervisor.intervene({:process, dummy}, :restart_component, :audit_test)

    assert :ok =
             RateLimiter.request_tokens(
               AuditReportTestRateLimiter,
               :audit_test_budget,
               :llm_call,
               :critical
             )

    assert {:error, :rate_limited} =
             RateLimiter.request_tokens(
               AuditReportTestRateLimiter,
               :audit_test_budget,
               :llm_call,
               :critical
             )

    # The intervention call above returns only after execute_intervention
    # ran; algedonic casts and the denial cast are ordered before the
    # report call through their own processes - synchronize via the log.
    wait_for_log_entries(5)

    to = DateTime.add(DateTime.utc_now(), 60, :second)
    report = ControlSupervisor.get_audit_report(from, to)
    audit = report.audit

    assert audit.events.algedonic_signals.total == 2
    assert audit.events.algedonic_signals.pain == 1
    assert audit.events.algedonic_signals.pleasure == 1
    assert audit.events.algedonic_signals.by_source == %{"test_source" => 2}

    assert audit.events.interventions.total == 1
    assert audit.events.interventions.succeeded == 1
    assert audit.events.component_restarts == 1

    assert audit.events.budget_denials.total == 1
    assert audit.events.budget_denials.by_key == %{":audit_test_budget" => 1}

    # The probes are in the report: the dedicated budget's real
    # token state is visible through the app's RateLimiter probe
    # path only for its own budgets, so assert the section shape.
    assert is_map(audit.resources.budgets)

    assert audit.compliance.chain_verified == true
    assert audit.compliance.compliant == true
    assert audit.compliance.violations == []
    assert audit.reconciliation.algedonic_signals.consistent == true

    # Tamper with today's file: the same report must now refuse to
    # claim compliance.
    file = Path.join(dir, Log.file_name(Date.utc_today()))
    lines = File.read!(file) |> String.split("\n", trim: true)

    tampered =
      lines
      |> List.update_at(0, &String.replace(&1, "test_source", "forged_src!"))
      |> Enum.join("\n")

    File.write!(file, tampered <> "\n")

    tampered_report = ControlSupervisor.get_audit_report(from, to)
    assert tampered_report.audit.compliance.chain_verified == false
    assert tampered_report.audit.compliance.compliant == false
    assert tampered_report.audit.anomalies != []
  end

  defp wait_for_log_entries(expected, attempts \\ 50) do
    entries = Log.entries_between()

    cond do
      length(entries) >= expected ->
        entries

      attempts <= 0 ->
        flunk("expected #{expected} audit entries, got #{length(entries)}: #{inspect(entries)}")

      true ->
        Process.sleep(20)
        wait_for_log_entries(expected, attempts - 1)
    end
  end
end
