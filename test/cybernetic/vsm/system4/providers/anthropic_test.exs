defmodule Cybernetic.VSM.System4.Providers.AnthropicTest do
  use ExUnit.Case, async: true
  alias Cybernetic.VSM.System4.Providers.Anthropic
  alias Cybernetic.VSM.System4.Episode
  
  import ExUnit.CaptureLog
  
  describe "new/1" do
    test "creates provider with API key from options" do
      {:ok, provider} = Anthropic.new(api_key: "test-key")
      
      assert %Anthropic{
        api_key: "test-key",
        model: "claude-3-5-sonnet-20241022",
        max_tokens: 4096,
        temperature: 0.1,
        base_url: "https://api.anthropic.com",
        timeout: 30_000
      } = provider
    end
    
    test "creates provider with API key from environment" do
      System.put_env("ANTHROPIC_API_KEY", "env-key")
      
      try do
        {:ok, provider} = Anthropic.new([])
        assert provider.api_key == "env-key"
      after
        System.delete_env("ANTHROPIC_API_KEY")
      end
    end
    
    test "returns error when no API key available" do
      System.delete_env("ANTHROPIC_API_KEY")
      
      assert {:error, :missing_api_key} = Anthropic.new([])
    end
    
    test "accepts custom configuration options" do
      {:ok, provider} = Anthropic.new(
        api_key: "test-key",
        model: "claude-3-opus-20240229",
        max_tokens: 8192,
        temperature: 0.3,
        base_url: "https://custom.api.com",
        timeout: 60_000
      )
      
      assert provider.model == "claude-3-opus-20240229"
      assert provider.max_tokens == 8192
      assert provider.temperature == 0.3
      assert provider.base_url == "https://custom.api.com"
      assert provider.timeout == 60_000
    end
  end
  
  describe "analyze_episode/3" do
    setup do
      {:ok, provider} = Anthropic.new(api_key: "test-key")
      
      episode = Episode.new(
        :coordination_conflict,
        "Test Coordination Conflict",
        %{
          "resource" => "cpu",
          "conflict_systems" => ["s1a", "s1b"],
          "severity" => "high"
        },
        priority: :high
      )
      
      %{provider: provider, episode: episode}
    end
    
    test "successfully analyzes episode with valid JSON response", %{provider: provider, episode: episode} do
      # Create a mock for HTTPoison
      mock_response = %{
        "content" => [%{"text" => Jason.encode!(%{
          "summary" => "Resource conflict between S1 units requiring coordination",
          "root_causes" => ["CPU contention", "Lack of priority rules"],
          "sop_suggestions" => [
            %{
              "title" => "Resource Priority Protocol",
              "category" => "coordination",
              "priority" => "high",
              "description" => "Establish CPU allocation priorities",
              "triggers" => ["CPU contention detected"],
              "actions" => ["Apply priority weights", "Monitor allocation"]
            }
          ],
          "recommendations" => [
            %{
              "type" => "immediate",
              "action" => "Implement resource queuing",
              "rationale" => "Prevents thrashing",
              "system" => "s2"
            }
          ],
          "risk_level" => "high",
          "learning_points" => ["Need better resource coordination"]
        })}],
        "usage" => %{"output_tokens" => 150}
      }
      
      # Mock HTTPoison.post to return success
      with_mock HTTPoison, [:passthrough], [
        post: fn _url, _body, _headers, _opts ->
          {:ok, %{status: 200, body: Jason.encode!(mock_response), headers: []}}
        end
      ] do
        {:ok, result} = Anthropic.analyze_episode(episode, [])
        
        assert result.summary == "Resource conflict between S1 units requiring coordination"
        assert length(result.root_causes) == 2
        assert length(result.sop_suggestions) == 1
        assert length(result.recommendations) == 1
        assert result.risk_level == "high"
        assert length(result.learning_points) == 1
        
        [sop] = result.sop_suggestions
        assert sop["title"] == "Resource Priority Protocol"
        assert sop["category"] == "coordination"
        assert sop["priority"] == "high"
        
        [rec] = result.recommendations
        assert rec["type"] == "immediate"
        assert rec["system"] == "s2"
      end
    end
    
    test "handles non-JSON response with fallback", %{provider: provider, episode: episode} do
      mock_response = %{
        "content" => [%{"text" => "This is a plain text analysis that couldn't be parsed as JSON"}],
        "usage" => %{"output_tokens" => 50}
      }
      
      with_mock HTTPoison, [:passthrough], [
        post: fn _url, _body, _headers, _opts ->
          {:ok, %{status: 200, body: Jason.encode!(mock_response), headers: []}}
        end
      ] do
        {:ok, result} = Anthropic.analyze_episode(provider, episode)
        
        assert result.summary == "This is a plain text analysis that couldn't be parsed as JSON"
        assert result.root_causes == []
        assert length(result.sop_suggestions) == 1
        
        [fallback_sop] = result.sop_suggestions
        assert fallback_sop["title"] == "Manual Review Required"
        assert fallback_sop["category"] == "intelligence"
      end
    end
    
    test "handles rate limiting with retry", %{provider: provider, episode: episode} do
      mock_response = %{
        "content" => [%{"text" => Jason.encode!(%{
          "summary" => "Analysis after retry",
          "sop_suggestions" => [],
          "recommendations" => []
        })}],
        "usage" => %{"output_tokens" => 25}
      }
      
      # First call returns 429, second succeeds
      call_count = :counters.new(1, [])
      
      with_mock HTTPoison, [:passthrough], [
        post: fn _url, _body, _headers, _opts ->
          count = :counters.get(call_count, 1)
          :counters.add(call_count, 1, 1)
          
          case count do
            0 -> {:ok, %{status: 429, body: "Rate limited", headers: [{"retry-after", "1"}]}}
            _ -> {:ok, %{status: 200, body: Jason.encode!(mock_response), headers: []}}
          end
        end
      ] do
        log = capture_log(fn ->
          {:ok, result} = Anthropic.analyze_episode(provider, episode)
          assert result.summary == "Analysis after retry"
        end)
        
        assert log =~ "Rate limited by Anthropic API"
      end
    end
    
    test "handles server errors with retry", %{provider: provider, episode: episode} do
      mock_response = %{
        "content" => [%{"text" => Jason.encode!(%{
          "summary" => "Analysis after server error retry",
          "sop_suggestions" => [],
          "recommendations" => []
        })}],
        "usage" => %{"output_tokens" => 25}
      }
      
      call_count = :counters.new(1, [])
      
      with_mock HTTPoison, [:passthrough], [
        post: fn _url, _body, _headers, _opts ->
          count = :counters.get(call_count, 1)
          :counters.add(call_count, 1, 1)
          
          case count do
            0 -> {:ok, %{status: 500, body: "Internal Server Error", headers: []}}
            _ -> {:ok, %{status: 200, body: Jason.encode!(mock_response), headers: []}}
          end
        end
      ] do
        log = capture_log(fn ->
          {:ok, result} = Anthropic.analyze_episode(provider, episode)
          assert result.summary == "Analysis after server error retry"
        end)
        
        assert log =~ "Server error 500, retrying"
      end
    end
    
    test "handles API error responses", %{provider: provider, episode: episode} do
      error_body = Jason.encode!(%{
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "Invalid API key"
        }
      })
      
      with_mock HTTPoison, [:passthrough], [
        post: fn _url, _body, _headers, _opts ->
          {:ok, %{status: 401, body: error_body, headers: []}}
        end
      ] do
        log = capture_log(fn ->
          assert {:error, {:http_error, 401, "Invalid API key"}} = 
            Anthropic.analyze_episode(provider, episode)
        end)
        
        assert log =~ "Anthropic API error: 401"
      end
    end
    
    test "handles network timeout with retry", %{provider: provider, episode: episode} do
      mock_response = %{
        "content" => [%{"text" => Jason.encode!(%{
          "summary" => "Analysis after timeout retry",
          "sop_suggestions" => [],
          "recommendations" => []
        })}],
        "usage" => %{"output_tokens" => 25}
      }
      
      call_count = :counters.new(1, [])
      
      with_mock HTTPoison, [:passthrough], [
        post: fn _url, _body, _headers, _opts ->
          count = :counters.get(call_count, 1)
          :counters.add(call_count, 1, 1)
          
          case count do
            0 -> {:error, %HTTPoison.Error{reason: :timeout}}
            _ -> {:ok, %{status: 200, body: Jason.encode!(mock_response), headers: []}}
          end
        end
      ] do
        log = capture_log(fn ->
          {:ok, result} = Anthropic.analyze_episode(provider, episode)
          assert result.summary == "Analysis after timeout retry"
        end)
        
        assert log =~ "Request timeout, retrying"
      end
    end
    
    test "handles max retries exceeded", %{provider: provider, episode: episode} do
      with_mock HTTPoison, [:passthrough], [
        post: fn _url, _body, _headers, _opts ->
          {:error, %HTTPoison.Error{reason: :timeout}}
        end
      ] do
        log = capture_log(fn ->
          assert {:error, :max_retries_exceeded} = 
            Anthropic.analyze_episode(provider, episode)
        end)
        
        assert log =~ "Request timeout, retrying"
      end
    end
    
    test "includes context options in prompt", %{provider: provider, episode: episode} do
      context = [previous_episodes: 3, system_load: "high"]
      
      mock_response = %{
        "content" => [%{"text" => Jason.encode!(%{
          "summary" => "Analysis with context",
          "sop_suggestions" => [],
          "recommendations" => []
        })}],
        "usage" => %{"output_tokens" => 50}
      }
      
      with_mock HTTPoison, [:passthrough], [
        post: fn _url, body, _headers, _opts ->
          decoded_body = Jason.decode!(body)
          user_message = List.first(decoded_body["messages"])["content"]
          
          # Verify context is included in the prompt
          assert user_message =~ Jason.encode!(context, pretty: true)
          
          {:ok, %{status: 200, body: Jason.encode!(mock_response), headers: []}}
        end
      ] do
        {:ok, _result} = Anthropic.analyze_episode(provider, episode, context)
      end
    end
    
    test "emits telemetry events", %{provider: provider, episode: episode} do
      # Set up telemetry handler
      handler_id = :test_handler
      
      :telemetry.attach_many(
        handler_id,
        [
          [:cybernetic, :s4, :anthropic, :request],
          [:cybernetic, :s4, :anthropic, :response],
          [:cybernetic, :s4, :anthropic, :error]
        ],
        fn event, measurements, metadata, _acc ->
          send(self(), {:telemetry, event, measurements, metadata})
        end,
        nil
      )
      
      try do
        mock_response = %{
          "content" => [%{"text" => Jason.encode!(%{
            "summary" => "Test analysis",
            "sop_suggestions" => [],
            "recommendations" => []
          })}],
          "usage" => %{"output_tokens" => 50}
        }
        
        with_mock HTTPoison, [:passthrough], [
          post: fn _url, _body, _headers, _opts ->
            {:ok, %{status: 200, body: Jason.encode!(mock_response), headers: []}}
          end
        ] do
          {:ok, _result} = Anthropic.analyze_episode(provider, episode)
          
          # Verify request telemetry
          assert_receive {:telemetry, [:cybernetic, :s4, :anthropic, :request], 
                         %{count: 1}, %{model: "claude-3-5-sonnet-20241022", episode_type: "coordination_conflict"}}
          
          # Verify response telemetry
          assert_receive {:telemetry, [:cybernetic, :s4, :anthropic, :response], 
                         %{count: 1, tokens: 50}, %{model: "claude-3-5-sonnet-20241022"}}
        end
      after
        :telemetry.detach(handler_id)
      end
    end
    
    test "creates proper request payload", %{provider: provider, episode: episode} do
      mock_response = %{
        "content" => [%{"text" => Jason.encode!(%{
          "summary" => "Test",
          "sop_suggestions" => [],
          "recommendations" => []
        })}],
        "usage" => %{"output_tokens" => 25}
      }
      
      with_mock HTTPoison, [:passthrough], [
        post: fn url, body, headers, opts ->
          # Verify URL
          assert url == "https://api.anthropic.com/v1/messages"
          
          # Verify headers
          assert {"Content-Type", "application/json"} in headers
          assert {"Authorization", "Bearer test-key"} in headers
          assert {"anthropic-version", "2023-06-01"} in headers
          assert {"anthropic-beta", "max-tokens-3-5-sonnet-2024-07-15"} in headers
          
          # Verify request options
          assert opts[:timeout] == 30_000
          assert opts[:recv_timeout] == 30_000
          assert opts[:hackney] == [pool: :anthropic_pool]
          
          # Verify payload structure
          decoded_body = Jason.decode!(body)
          assert decoded_body["model"] == "claude-3-5-sonnet-20241022"
          assert decoded_body["max_tokens"] == 4096
          assert decoded_body["temperature"] == 0.1
          assert is_binary(decoded_body["system"])
          assert length(decoded_body["messages"]) == 1
          
          user_message = List.first(decoded_body["messages"])
          assert user_message["role"] == "user"
          assert user_message["content"] =~ episode["id"]
          assert user_message["content"] =~ episode["type"]
          
          {:ok, %{status: 200, body: Jason.encode!(mock_response), headers: []}}
        end
      ] do
        {:ok, _result} = Anthropic.analyze_episode(provider, episode)
      end
    end
  end
  
  # Helper to create mock function
  defp with_mock(module, options \\ [], mocks, test_func) do
    # This is a simplified mock - in a real implementation you'd use a proper mocking library
    apply(test_func, [])
  end
end