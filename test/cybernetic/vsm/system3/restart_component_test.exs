defmodule Cybernetic.VSM.System3.RestartComponentTest.Dummy do
  @moduledoc false
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)

  @impl true
  def init(:ok), do: {:ok, %{}}
end

defmodule Cybernetic.VSM.System3.RestartComponentTest do
  @moduledoc """
  The S3 automatic-restart intervention must address VSM.Supervisor
  children by their real ids (the child modules). Addressing them as
  :"system\#{n}" returns {:error, :not_found} - and the result used
  to be discarded, so restarts reported success while never
  happening. These tests prove a restart addressed as {:system, 2}
  really restarts the System2.Coordinator child, and that an
  unresolvable target reports an error instead of fake success.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.VSM.System2.Coordinator
  alias Cybernetic.VSM.System3.ControlSupervisor
  alias Cybernetic.VSM.System3.RestartComponentTest.Dummy

  setup do
    # Stand in a VSM.Supervisor that, like the real one, has a child
    # whose id is the Coordinator module itself. Linked to the test
    # process; dies with it.
    if Process.whereis(Cybernetic.VSM.Supervisor) == nil do
      children = [
        %{id: Coordinator, start: {Dummy, :start_link, [Coordinator]}}
      ]

      {:ok, _pid} =
        Supervisor.start_link(children, strategy: :one_for_one, name: Cybernetic.VSM.Supervisor)
    end

    stop_control_supervisor()

    cs_pid =
      case ControlSupervisor.start_link() do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

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

  test "intervene restart on {:system, 2} really restarts the Coordinator child" do
    before_pid = Process.whereis(Coordinator)
    assert is_pid(before_pid)

    assert {:ok, _intervention_id} =
             ControlSupervisor.intervene({:system, 2}, :restart_component, :test_restart)

    after_pid = Process.whereis(Coordinator)
    assert is_pid(after_pid)
    assert after_pid != before_pid
    assert Process.alive?(after_pid)
  end

  test "intervene restart on an unknown system reports an error, not fake success" do
    assert {:error, :invalid_target} =
             ControlSupervisor.intervene({:system, 9}, :restart_component, :test_restart)
  end
end
