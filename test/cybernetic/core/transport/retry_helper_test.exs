defmodule Cybernetic.Core.Transport.RetryHelperTest do
  @moduledoc """
  IP-30: unit tests for `Cybernetic.Core.Transport.RetryHelper`,
  the retry helper the two AMQP consumers now wire into their
  reject sites. Broker-free: `with_retry/4` is exercised without a
  channel, which exercises the counting, outcome, and poison paths
  (the republish itself needs a broker and is not covered here).
  """
  use ExUnit.Case, async: true

  alias Cybernetic.Core.Transport.RetryHelper

  describe "headers_map/1" do
    test "converts AMQP {name, type, value} header tuples to a plain map" do
      headers = [
        {"_retries", :signedint, 2},
        {"correlation_id", :longstr, "abc"}
      ]

      assert RetryHelper.headers_map(headers) == %{
               "_retries" => 2,
               "correlation_id" => "abc"
             }
    end

    test "nil and non-list headers become an empty map" do
      assert RetryHelper.headers_map(nil) == %{}
      assert RetryHelper.headers_map(%{}) == %{}
    end
  end

  describe "retry counting" do
    test "get_retry_count/1 reads integer and binary counts, defaulting to 0" do
      assert RetryHelper.get_retry_count(%{}) == 0
      assert RetryHelper.get_retry_count(%{"_retries" => 3}) == 3
      assert RetryHelper.get_retry_count(%{"_retries" => "4"}) == 4
      assert RetryHelper.get_retry_count(%{"_retries" => "junk"}) == 0
    end

    test "increment_retry/1 advances the count" do
      assert RetryHelper.increment_retry(%{}) == %{"_retries" => 1}
      assert RetryHelper.increment_retry(%{"_retries" => 2}) == %{"_retries" => 3}
    end
  end

  describe "with_retry/4" do
    test "passes a successful result through" do
      assert :ok = RetryHelper.with_retry(%{}, "payload", fn -> :ok end)
      assert {:ok, 42} = RetryHelper.with_retry(%{}, "payload", fn -> {:ok, 42} end)
    end

    test "returns the failure when the attempt errors below the retry cap" do
      assert {:error, :boom} =
               RetryHelper.with_retry(%{}, "payload", fn -> {:error, :boom} end)

      assert {:error, :boom} =
               RetryHelper.with_retry(%{"_retries" => 2}, "payload", fn ->
                 {:error, :boom}
               end)
    end

    test "poison at the retry cap: the attempt is never run" do
      test_pid = self()

      assert {:error, :poison} =
               RetryHelper.with_retry(%{"_retries" => 5}, %{"type" => "x"}, fn ->
                 send(test_pid, :attempt_ran)
                 :ok
               end)

      refute_received :attempt_ran
    end
  end
end
