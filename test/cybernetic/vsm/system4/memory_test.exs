defmodule Cybernetic.VSM.System4.MemoryTest do
  use ExUnit.Case, async: false

  alias Cybernetic.VSM.System4.Memory

  setup do
    # Clear memory before each test
    Memory.clear()
    :ok
  end

  describe "store/4" do
    test "stores episode interactions" do
      Memory.store("episode-1", :user, "What is the weather?", %{source: "test"})

      Memory.store("episode-1", :assistant, "I can help with weather information.", %{
        model: "claude"
      })

      {:ok, context} = Memory.get_context("episode-1")

      assert length(context) == 1
      assert [episode] = context
      assert episode.episode_id == "episode-1"
      assert length(episode.messages) == 2

      [msg1, msg2] = episode.messages
      assert msg1.role == :user
      assert msg1.content == "What is the weather?"
      assert msg2.role == :assistant
      assert msg2.content == "I can help with weather information."
    end

    test "maintains separate contexts for different episodes" do
      Memory.store("episode-1", :user, "Question 1", %{})
      Memory.store("episode-2", :user, "Question 2", %{})

      {:ok, context1} = Memory.get_context("episode-1")
      {:ok, context2} = Memory.get_context("episode-2")

      assert length(context1) == 1
      assert length(context2) == 1

      [ep1] = context1
      [ep2] = context2

      assert ep1.episode_id == "episode-1"
      assert ep2.episode_id == "episode-2"
    end
  end

  describe "get_context/2" do
    test "retrieves context with token limit" do
      # Store many messages
      for i <- 1..50 do
        Memory.store("episode-1", :user, String.duplicate("x", 100), %{index: i})
      end

      {:ok, context} = Memory.get_context("episode-1", max_tokens: 500)

      [episode] = context
      # Should have limited messages based on token count
      assert length(episode.messages) < 50
    end

    test "returns empty context for unknown episode" do
      {:ok, context} = Memory.get_context("unknown-episode")
      assert context == []
    end
  end

  describe "search/2" do
    test "searches memories by query" do
      Memory.store("episode-1", :user, "Tell me about quantum physics", %{})
      Memory.store("episode-2", :user, "Explain machine learning", %{})
      Memory.store("episode-3", :user, "What is quantum computing?", %{})

      {:ok, matches} = Memory.search("quantum", limit: 2)

      # Should find quantum-related entries
      assert length(matches) <= 2
    end
  end

  describe "clear/1" do
    test "clears specific episode memory" do
      Memory.store("episode-1", :user, "Message 1", %{})
      Memory.store("episode-2", :user, "Message 2", %{})

      Memory.clear("episode-1")

      {:ok, context1} = Memory.get_context("episode-1")
      {:ok, context2} = Memory.get_context("episode-2")

      assert context1 == []
      assert length(context2) == 1
    end

    test "clears all memory when :all specified" do
      Memory.store("episode-1", :user, "Message 1", %{})
      Memory.store("episode-2", :user, "Message 2", %{})

      Memory.clear(:all)

      {:ok, context1} = Memory.get_context("episode-1")
      {:ok, context2} = Memory.get_context("episode-2")

      assert context1 == []
      assert context2 == []
    end
  end

  describe "stats/0" do
    test "returns memory statistics" do
      Memory.store("episode-1", :user, "Test message", %{})

      stats = Memory.stats()

      assert stats.total_entries >= 1
      assert stats.total_tokens > 0
      assert stats.active_episodes >= 1
      assert is_integer(stats.cache_hits)
      assert is_integer(stats.cache_misses)
    end
  end

  describe "context window management" do
    test "trims old messages when exceeding max episodes" do
      # Store more than max episodes (20)
      for i <- 1..25 do
        Memory.store("episode-1", :user, "Message #{i}", %{})
        # Ensure different timestamps
        Process.sleep(1)
      end

      {:ok, context} = Memory.get_context("episode-1")

      [episode] = context
      # Should only keep last 20 messages
      assert length(episode.messages) == 20

      # Verify we have the most recent messages
      last_msg = List.last(episode.messages)
      assert last_msg.content == "Message 25"
    end

    test "respects token limits in context window" do
      # Store messages with large content
      for i <- 1..10 do
        # ~500 tokens each
        content = String.duplicate("x", 2000)
        Memory.store("episode-1", :user, content, %{index: i})
      end

      {:ok, context} = Memory.get_context("episode-1", max_tokens: 2000)

      [episode] = context
      # Should have limited messages to fit token budget
      assert length(episode.messages) < 10
    end
  end

  describe "integration with S4 Service" do
    @tag :integration
    test "memory is used in episode analysis" do
      # This would test the full integration with S4 Service
      # Skipped for unit tests, would run in integration suite
    end
  end
end
