defmodule Cybernetic.VSM.System2.MessageHandlerCoordinationTest do
  @moduledoc """
  coordinate_operation must do real coordination: reserve actual
  slots from the System2 Coordinator and report what was really
  allocated or denied, instead of returning fixed values.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.VSM.System2.Coordinator
  alias Cybernetic.VSM.System2.MessageHandler

  setup do
    # config/runtime.exs forces the AMQP transport even in test env,
    # which would route the S4 forward away from the in-memory
    # collector. Point the transport at InMemory for these tests and
    # restore the previous value afterwards.
    previous_transport = Application.get_env(:cybernetic, :transport)
    Application.put_env(:cybernetic, :transport, Cybernetic.Transport.InMemory)
    Cybernetic.Transport.InMemory.set_test_collector(self())

    on_exit(fn ->
      Cybernetic.Transport.InMemory.set_test_collector(nil)

      if previous_transport do
        Application.put_env(:cybernetic, :transport, previous_transport)
      else
        Application.delete_env(:cybernetic, :transport)
      end

      stop_coordinator()
    end)

    :ok
  end

  defp stop_coordinator do
    if pid = Process.whereis(Coordinator) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp start_coordinator(opts \\ []) do
    stop_coordinator()

    case Coordinator.start_link(opts) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp coordinate(payload) do
    assert :ok = MessageHandler.handle_message("coordinate", payload, %{})

    assert_receive {:system4_message, msg}, 1_000
    msg["coordination_data"]
  end

  test "allocates the requested lanes from the Coordinator" do
    start_coordinator()

    data =
      coordinate(%{
        "type" => "vsm.s2.coordinate",
        "coordination_id" => "coord_input_1",
        "target_systems" => ["lane_alpha", "lane_beta"]
      })

    assert data["coordination_id"] == "coord_input_1"
    assert data["status"] == "coordinated"
    assert Enum.sort(data["resources_allocated"]) == ["lane_alpha", "lane_beta"]
    assert data["resources_denied"] == []
  end

  test "result varies with the request: different lanes in, different allocation out" do
    start_coordinator()

    data =
      coordinate(%{
        "type" => "vsm.s2.coordinate",
        "target_systems" => ["lane_gamma"]
      })

    assert data["resources_allocated"] == ["lane_gamma"]
    refute "worker_1" in data["resources_allocated"]
    refute "worker_2" in data["resources_allocated"]
  end

  test "reports backpressure once a lane's real slots are exhausted" do
    start_coordinator(max_slots: 1)

    first =
      coordinate(%{
        "type" => "vsm.s2.coordinate",
        "target_systems" => ["lane_delta"]
      })

    assert first["status"] == "coordinated"
    assert first["resources_allocated"] == ["lane_delta"]

    second =
      coordinate(%{
        "type" => "vsm.s2.coordinate",
        "target_systems" => ["lane_delta"]
      })

    assert second["status"] == "backpressure"
    assert second["resources_allocated"] == []
    assert second["resources_denied"] == ["lane_delta"]
  end

  test "coordination_complete releases the lane's slot again" do
    start_coordinator(max_slots: 1)

    first =
      coordinate(%{
        "type" => "vsm.s2.coordinate",
        "coordination_id" => "coord_cycle_1",
        "target_systems" => ["lane_epsilon"]
      })

    assert first["status"] == "coordinated"

    assert :ok =
             MessageHandler.handle_message(
               "coordination_complete",
               %{
                 "type" => "vsm.s2.coordination_complete",
                 "coordination_id" => "coord_cycle_1",
                 "resources_allocated" => ["lane_epsilon"]
               },
               %{}
             )

    # The completion forwarded an intelligence message; drain it
    assert_receive {:system4_message, _}, 1_000

    again =
      coordinate(%{
        "type" => "vsm.s2.coordinate",
        "target_systems" => ["lane_epsilon"]
      })

    assert again["status"] == "coordinated"
    assert again["resources_allocated"] == ["lane_epsilon"]
  end

  test "reports coordinator_unavailable instead of fabricating an allocation" do
    stop_coordinator()
    assert Process.whereis(Coordinator) == nil

    data =
      coordinate(%{
        "type" => "vsm.s2.coordinate",
        "target_systems" => ["lane_zeta"]
      })

    assert data["status"] == "coordinator_unavailable"
    assert data["resources_allocated"] == []
    assert data["resources_denied"] == ["lane_zeta"]
  end
end
