defmodule Cybernetic.VSM.System3.ControlSupervisorHealthTest do
  @moduledoc """
  S3 health must be computed from real inputs: ControlSupervisor
  queries the processes that represent S1/S2. When they are down the
  aggregate health is :failed, the control state goes :critical and
  the automatic intervention path - previously unreachable behind a
  hard-coded :healthy - fires. When they are up, health is :healthy.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.VSM.System3.ControlSupervisor

  setup do
    # restart_component/1 calls Supervisor.restart_child on
    # Cybernetic.VSM.Supervisor; stand in an empty supervisor under
    # that name (restart_child on it returns {:error, :not_found},
    # which restart_component already tolerates). It is linked to
    # the test process and dies with it.
    if Process.whereis(Cybernetic.VSM.Supervisor) == nil do
      {:ok, _pid} =
        Supervisor.start_link([], strategy: :one_for_one, name: Cybernetic.VSM.Supervisor)
    end

    stop_control_supervisor()

    # Linked to the test process; dies with it at test end.
    cs_pid =
      case ControlSupervisor.start_link() do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    on_exit(fn ->
      for name <- [Cybernetic.VSM.System1.Operational, Cybernetic.VSM.System2.Coordinator] do
        if pid = Process.whereis(name), do: Process.exit(pid, :kill)
      end
    end)

    {:ok, cs: cs_pid}
  end

  defp stop_control_supervisor do
    if pid = Process.whereis(ControlSupervisor) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp run_health_check(pid) do
    send(pid, :health_check)
    # handle_info is async; give it a moment to complete the cycle
    Process.sleep(150)
    ControlSupervisor.get_status()
  end

  defp register_dummy(name) do
    if Process.whereis(name) == nil do
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      Process.register(pid, name)
      pid
    end
  end

  test "systems down: health is :failed, state :critical, intervention fires", %{cs: cs} do
    assert Process.whereis(Cybernetic.VSM.System1.Operational) == nil
    assert Process.whereis(Cybernetic.VSM.System2.Coordinator) == nil

    status = run_health_check(cs)

    assert status.health_status == :failed
    assert status.control_state == :critical
    assert status.active_interventions >= 1
  end

  test "systems up: health is :healthy and no intervention fires", %{cs: cs} do
    register_dummy(Cybernetic.VSM.System1.Operational)
    register_dummy(Cybernetic.VSM.System2.Coordinator)

    status = run_health_check(cs)

    assert status.health_status == :healthy
    assert status.control_state == :normal
    assert status.active_interventions == 0
  end

  test "one system down is enough to fail the aggregate and intervene", %{cs: cs} do
    register_dummy(Cybernetic.VSM.System1.Operational)
    assert Process.whereis(Cybernetic.VSM.System2.Coordinator) == nil

    status = run_health_check(cs)

    assert status.health_status == :failed
    assert status.control_state == :critical
    assert status.active_interventions >= 1
  end
end
