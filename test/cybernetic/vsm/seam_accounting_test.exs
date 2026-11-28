defmodule Cybernetic.VSM.SeamAccountingTest do
  @moduledoc """
  Phase 2 amendment (WC G5): poison settlements at the two
  consumer dispatch seams record a :dead_letter audit entry -
  the transport layer's own incident record, written by a path
  no reflex rule consumes. It is the independent incident
  source the shadow FN join reads (an incident the rules did
  not have to see for it to exist). The record fires once per
  unit of work: at the first poison determination, not on
  redeliveries (WC G3's attempts-are-not-work conditioning).
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Audit.Log
  alias Cybernetic.VSM.AMQPConsumer
  alias Cybernetic.VSM.System4.AMQPConsumer, as: S4Consumer

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "seam-accounting-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    {:ok, log_pid} = Log.start_link(dir: dir)

    on_exit(fn ->
      if Process.alive?(log_pid), do: GenServer.stop(log_pid)
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp dead_letters do
    # Log.record/2 is a cast; head/0 is a call queued behind it.
    Log.head()
    Log.entries_between() |> Enum.filter(&(&1["type"] == "dead_letter"))
  end

  test "poison at both seams records one :dead_letter each; a poison redelivery records none" do
    assert :reject =
             AMQPConsumer.dispatch_with_retry(
               :system1,
               %{"operation" => "status_update"},
               ~s({"operation":"status_update"}),
               %{routing_key: "s1.status_update.dl", headers: [{"_retries", :signedint, 5}]}
             )

    assert :reject =
             S4Consumer.process_delivery(
               %{"operation" => "intelligence"},
               ~s({"operation":"intelligence"}),
               %{routing_key: "s4.reason.dl", headers: [{"_retries", :signedint, 5}]}
             )

    entries = dead_letters()
    assert length(entries) == 2

    seams = entries |> Enum.map(& &1["payload"]["seam"]) |> Enum.sort()
    assert seams == ["system4_consumer", "vsm_consumer"]

    assert Enum.all?(entries, &(&1["payload"]["reason"] == "poison"))

    # The same unit redelivered past the max: no second record.
    assert :reject =
             AMQPConsumer.dispatch_with_retry(
               :system1,
               %{"operation" => "status_update"},
               ~s({"operation":"status_update"}),
               %{routing_key: "s1.status_update.dl", headers: [{"_retries", :signedint, 6}]}
             )

    assert length(dead_letters()) == 2
  end
end
