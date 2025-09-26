defmodule Cybernetic.Core.Security.RateLimiterTest do
  use ExUnit.Case
  alias Cybernetic.Core.Security.RateLimiter

  setup do
    # Stop existing if running and start fresh for tests
    case Process.whereis(RateLimiter) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 100)
    end

    Process.sleep(10)
    {:ok, pid} = RateLimiter.start_link(bucket_size: 10, refill_rate: 5)
    {:ok, limiter: pid}
  end

  describe "rate limiting" do
    test "allows requests within limit" do
      assert {:ok, _remaining} = RateLimiter.check("test_key", 5)
      assert {:ok, remaining} = RateLimiter.consume("test_key", 5)
      assert remaining == 5
    end

    test "blocks requests over limit" do
      assert {:ok, _} = RateLimiter.consume("test_key", 10)
      assert {:error, :rate_limited} = RateLimiter.consume("test_key", 1)
    end

    test "refills tokens over time" do
      key = "refill_test"
      assert {:ok, 0} = RateLimiter.consume(key, 10)

      # Wait for refill (5 tokens per second, wait 400ms = 2 tokens)
      Process.sleep(400)

      assert {:ok, _remaining} = RateLimiter.consume(key, 2)
    end

    test "check doesn't consume tokens" do
      key = "check_test"
      assert {:ok, 10} = RateLimiter.check(key)
      assert {:ok, 10} = RateLimiter.check(key)
      assert {:ok, 10} = RateLimiter.check(key, 5)
    end

    test "get_bucket returns current state" do
      key = "bucket_test"
      assert {:ok, 5} = RateLimiter.consume(key, 5)

      bucket = RateLimiter.get_bucket(key)
      assert bucket.tokens == 5
      assert is_integer(bucket.last_refill)
    end

    test "reset restores full capacity" do
      key = "reset_test"
      assert {:ok, 0} = RateLimiter.consume(key, 10)

      RateLimiter.reset(key)
      # Let cast complete
      Process.sleep(10)

      assert {:ok, 10} = RateLimiter.check(key)
    end

    test "different keys have independent buckets" do
      assert {:ok, 5} = RateLimiter.consume("key1", 5)
      assert {:ok, 3} = RateLimiter.consume("key2", 7)

      bucket1 = RateLimiter.get_bucket("key1")
      bucket2 = RateLimiter.get_bucket("key2")

      assert bucket1.tokens == 5
      assert bucket2.tokens == 3
    end

    test "handles concurrent requests correctly" do
      key = "concurrent_test"

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            RateLimiter.consume(key, 1)
          end)
        end

      results = Task.await_many(tasks)

      successful =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      # Should allow exactly 10 requests (bucket size)
      assert successful == 10
    end
  end
end
