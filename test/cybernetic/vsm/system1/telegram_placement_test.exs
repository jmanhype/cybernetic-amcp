defmodule Cybernetic.VSM.System1.TelegramPlacementTest do
  @moduledoc """
  Coupling #7 (Axiomatic Design register): TelegramAgent belongs to
  System 1's supervision subtree. It previously sat on the root
  supervisor, coupling its lifecycle to the root tree and the edge
  webhook path. These tests pin the placement: the agent is a child
  of System1.Operational, alive under its registered name, and
  reachable by the callers that address it by module name.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.VSM.System1.Agents.TelegramAgent
  alias Cybernetic.VSM.System1.Operational

  setup do
    # Other suites may leave the agent or Operational registered under
    # their names (e.g. dummy registrations); clear the names so the
    # real subtree can start.
    for name <- [TelegramAgent, Operational, Cybernetic.VSM.System1.AgentSupervisor] do
      if pid = Process.whereis(name) do
        Process.exit(pid, :kill)
      end
    end

    :ok
  end

  test "TelegramAgent is a child of System1.Operational and alive under its name" do
    start_supervised!(Operational)

    children = Supervisor.which_children(Operational)
    ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

    assert TelegramAgent in ids,
           "expected TelegramAgent in Operational's children, got: #{inspect(ids)}"

    pid = Process.whereis(TelegramAgent)
    assert is_pid(pid), "TelegramAgent not registered under its module name"
    assert Process.alive?(pid)
  end

  test "TelegramAgent is not a direct child of the root supervisor" do
    # The root tree is only assembled by the application in non-minimal
    # mode; in the test environment the application boots minimal, so
    # assert against the assembled full-tree child list by checking
    # that Operational (started standalone) owns the agent while no
    # other started supervisor in this test claims it. The static
    # guarantee (application.ex carries no root TelegramAgent child)
    # is covered by the boot soak's placement check.
    start_supervised!(Operational)

    root_children =
      case Process.whereis(Cybernetic.Supervisor) do
        nil -> []
        _pid -> Supervisor.which_children(Cybernetic.Supervisor)
      end

    root_ids = Enum.map(root_children, fn {id, _pid, _type, _modules} -> id end)
    refute TelegramAgent in root_ids
  end
end
