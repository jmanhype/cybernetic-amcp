defmodule Cybernetic.VSM.AlgedonicLoopTest do
  @moduledoc """
  Coupling #3 (Axiomatic Design register): the algedonic loop was
  three unconnected partial DPs — S1 emitted to S4, S4's handler
  dead-ended in telemetry, and S3 ControlSupervisor's algedonic
  machinery (buffer, thresholds, intervention) had no production
  caller. These tests prove S4's handler now forwards into
  ControlSupervisor: pain escalates state and, at intervention
  intensity, creates a real intervention.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.VSM.System3.ControlSupervisor
  alias Cybernetic.VSM.System4.MessageHandler

  setup do
    pid =
      case ControlSupervisor.start_link() do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    {:ok, control_supervisor: pid}
  end

  test "S4 pain signals reach S3: buffered, state escalates, intervention at high intensity" do
    # Mild pain (0.5) is below the processing threshold: buffered
    # only, control state unchanged.
    before = ControlSupervisor.get_status()

    assert :ok =
             MessageHandler.handle_message(
               "algedonic",
               %{
                 "type" => "algedonic.pain",
                 "source_system" => "s1",
                 "data" => %{severity: :mild}
               },
               %{}
             )

    Process.sleep(100)
    status = ControlSupervisor.get_status()
    assert status.control_state == before.control_state

    assert Enum.any?(status.recent_algedonic, fn signal ->
             signal.type == :pain and signal.intensity == 0.5 and signal.source == :s1
           end)

    # Severe pain (0.85) crosses the intervention threshold: S3 goes
    # critical and opens a real intervention targeted at S1.
    interventions_before = status.active_interventions

    assert :ok =
             MessageHandler.handle_message(
               "algedonic",
               %{
                 "type" => "algedonic.pain",
                 "source_system" => "s1",
                 "data" => %{severity: :severe}
               },
               %{}
             )

    Process.sleep(100)
    status = ControlSupervisor.get_status()
    assert status.control_state == :critical
    assert status.active_interventions > interventions_before

    assert Enum.any?(status.recent_algedonic, fn signal ->
             signal.type == :pain and signal.intensity == 0.85 and signal.source == :s1
           end)
  end

  test "S4 pleasure signals are buffered by S3" do
    assert :ok =
             MessageHandler.handle_message(
               "algedonic",
               %{
                 "type" => "algedonic.pleasure",
                 "source_system" => "s1",
                 "data" => %{intensity: :high}
               },
               %{}
             )

    Process.sleep(100)
    status = ControlSupervisor.get_status()

    assert Enum.any?(status.recent_algedonic, fn signal ->
             signal.type == :pleasure and signal.intensity == 0.85 and signal.source == :s1
           end)
  end
end
