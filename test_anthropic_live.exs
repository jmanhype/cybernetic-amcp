#!/usr/bin/env elixir

# Live test script for Anthropic provider
# Run with: elixir test_anthropic_live.exs

Mix.install([
  {:jason, "~> 1.4"},
  {:httpoison, "~> 2.2"}
])

defmodule Cybernetic.VSM.System4.Providers.Anthropic do
  @moduledoc """
  Anthropic Claude provider for S4 Intelligence system.
  
  Implements the LLM provider behavior for episode analysis using Claude's
  reasoning capabilities for VSM decision-making and SOP recommendations.
  """
  
  require Logger
  
  @default_model "claude-3-5-sonnet-20241022"
  @default_max_tokens 4096
  @default_temperature 0.1
  @telemetry [:cybernetic, :s4, :anthropic]
  
  defstruct [
    :api_key,
    :model,
    :max_tokens,
    :temperature,
    :base_url,
    :timeout
  ]
  
  @type t :: %__MODULE__{
    api_key: String.t(),
    model: String.t(),
    max_tokens: pos_integer(),
    temperature: float(),
    base_url: String.t(),
    timeout: pos_integer()
  }
  
  @doc """
  Creates a new Anthropic provider instance.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")
    
    unless api_key do
      {:error, :missing_api_key}
    else
      provider = %__MODULE__{
        api_key: api_key,
        model: Keyword.get(opts, :model, @default_model),
        max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
        temperature: Keyword.get(opts, :temperature, @default_temperature),
        base_url: Keyword.get(opts, :base_url, "https://api.anthropic.com"),
        timeout: Keyword.get(opts, :timeout, 30_000)
      }
      
      {:ok, provider}
    end
  end
  
  def analyze_episode(provider, episode, context_opts \\ []) do
    prompt = build_analysis_prompt(provider, episode, context_opts)
    
    case make_anthropic_request(provider, prompt) do
      {:ok, response} ->
        parse_analysis_response(response)
        
      {:error, reason} = error ->
        Logger.error("Anthropic API request failed: #{inspect(reason)}")
        error
    end
  end
  
  defp build_analysis_prompt(provider, episode, context_opts) do
    system_prompt = """
    You are the S4 Intelligence system in a Viable System Model (VSM) framework.
    Your role is to analyze operational episodes and provide strategic recommendations.
    
    Analyze the given episode and provide:
    1. Root cause analysis using systems thinking
    2. Specific SOP (Standard Operating Procedure) recommendations
    3. Risk assessment and mitigation strategies
    4. Learning opportunities for the organization
    
    Respond in JSON format with the following structure:
    {
      "summary": "Brief analysis summary",
      "root_causes": ["cause1", "cause2"],
      "sop_suggestions": [
        {
          "title": "SOP Title", 
          "category": "operational|coordination|control|intelligence|policy",
          "priority": "high|medium|low",
          "description": "Detailed SOP description",
          "triggers": ["when to apply this SOP"],
          "actions": ["step1", "step2"]
        }
      ],
      "recommendations": [
        {
          "type": "immediate|short_term|long_term",
          "action": "Specific recommendation",
          "rationale": "Why this is important",
          "system": "s1|s2|s3|s4|s5"
        }
      ],
      "risk_level": "low|medium|high|critical",
      "learning_points": ["key insight 1", "key insight 2"]
    }
    """
    
    user_prompt = """
    Episode to analyze:
    
    ID: #{episode["id"]}
    Type: #{episode["type"]}
    Severity: #{episode["severity"]}
    Timestamp: #{episode["timestamp"]}
    
    Details:
    #{Jason.encode!(episode, pretty: true)}
    
    Context:
    #{if context_opts != [], do: Jason.encode!(context_opts, pretty: true), else: "No additional context"}
    
    Please analyze this episode and provide structured recommendations.
    """
    
    %{
      "model" => provider.model,
      "max_tokens" => provider.max_tokens,
      "temperature" => provider.temperature,
      "system" => system_prompt,
      "messages" => [
        %{
          "role" => "user",
          "content" => user_prompt
        }
      ]
    }
  end
  
  defp make_anthropic_request(provider, payload) do
    url = "#{provider.base_url}/v1/messages"
    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{provider.api_key}"},
      {"anthropic-version", "2023-06-01"}
    ]
    
    options = [
      timeout: provider.timeout,
      recv_timeout: provider.timeout
    ]
    
    with {:ok, json} <- Jason.encode(payload),
         {:ok, %{status: 200, body: body}} <- 
           HTTPoison.post(url, json, headers, options),
         {:ok, response} <- Jason.decode(body) do
      {:ok, response}
    else
      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic API error: #{status} - #{body}")
        {:error, {:http_error, status, body}}
        
      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("HTTP request failed: #{inspect(reason)}")
        {:error, {:network_error, reason}}
        
      {:error, reason} ->
        Logger.error("JSON encoding/decoding failed: #{inspect(reason)}")
        {:error, {:json_error, reason}}
    end
  end
  
  defp parse_analysis_response(response) do
    case response do
      %{"content" => [%{"text" => text}]} ->
        case Jason.decode(text) do
          {:ok, parsed} ->
            result = %{
              summary: parsed["summary"],
              root_causes: parsed["root_causes"] || [],
              sop_suggestions: parsed["sop_suggestions"] || [],
              recommendations: parsed["recommendations"] || [],
              risk_level: parsed["risk_level"] || "medium",
              learning_points: parsed["learning_points"] || []
            }
            
            {:ok, result}
            
          {:error, _} ->
            # Fallback for non-JSON responses
            {:ok, %{
              summary: text,
              root_causes: [],
              sop_suggestions: [%{
                "title" => "Manual Review Required",
                "category" => "intelligence",
                "priority" => "medium",
                "description" => "Response requires manual parsing",
                "triggers" => ["non-structured LLM response"],
                "actions" => ["review raw response", "extract insights manually"]
              }],
              recommendations: [],
              risk_level: "medium",
              learning_points: []
            }}
        end
        
      _ ->
        {:error, {:unexpected_response_format, response}}
    end
  end
end

# Test the provider
defmodule LiveTest do
  def run do
    IO.puts("🧠 Testing Anthropic Provider for Cybernetic VSM Framework")
    IO.puts("=" * 60)
    
    # Test episode - S1 operational overload scenario
    episode = %{
      "id" => "ep-live-test-#{System.unique_integer()}",
      "type" => "operational_overload",
      "severity" => "high",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "details" => %{
        "system" => "s1_worker_pool",
        "cpu_usage" => 0.95,
        "memory_usage" => 0.87,
        "queue_depth" => 1247,
        "error_rate" => 0.12,
        "response_time_p95" => 2500
      },
      "metadata" => %{
        "duration_ms" => 180_000,
        "affected_workers" => 8,
        "peak_load" => true,
        "auto_scaling_triggered" => false
      }
    }
    
    # Create provider
    api_key = "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"
    
    case Cybernetic.VSM.System4.Providers.Anthropic.new(api_key: api_key) do
      {:ok, provider} ->
        IO.puts("✅ Provider created successfully")
        IO.puts("   Model: #{provider.model}")
        IO.puts("   Timeout: #{provider.timeout}ms")
        IO.puts()
        
        IO.puts("📊 Episode Details:")
        IO.puts("   ID: #{episode["id"]}")
        IO.puts("   Type: #{episode["type"]}")
        IO.puts("   Severity: #{episode["severity"]}")
        IO.puts("   CPU Usage: #{episode["details"]["cpu_usage"] * 100}%")
        IO.puts("   Memory Usage: #{episode["details"]["memory_usage"] * 100}%")
        IO.puts("   Queue Depth: #{episode["details"]["queue_depth"]}")
        IO.puts()
        
        IO.puts("🔄 Sending to Claude for analysis...")
        
        case Cybernetic.VSM.System4.Providers.Anthropic.analyze_episode(provider, episode) do
          {:ok, result} ->
            IO.puts("✅ Analysis completed successfully!")
            IO.puts()
            
            IO.puts("📋 SUMMARY:")
            IO.puts("   #{result.summary}")
            IO.puts()
            
            IO.puts("🎯 RISK LEVEL: #{String.upcase(result.risk_level)}")
            IO.puts()
            
            if length(result.root_causes) > 0 do
              IO.puts("🔍 ROOT CAUSES:")
              Enum.each(result.root_causes, fn cause ->
                IO.puts("   • #{cause}")
              end)
              IO.puts()
            end
            
            if length(result.sop_suggestions) > 0 do
              IO.puts("📚 SOP SUGGESTIONS:")
              Enum.with_index(result.sop_suggestions, 1)
              |> Enum.each(fn {sop, index} ->
                IO.puts("   #{index}. #{sop["title"]} (#{sop["priority"]} priority)")
                IO.puts("      Category: #{sop["category"]}")
                IO.puts("      Description: #{sop["description"]}")
                if sop["triggers"] do
                  IO.puts("      Triggers: #{Enum.join(sop["triggers"], ", ")}")
                end
                IO.puts()
              end)
            end
            
            if length(result.recommendations) > 0 do
              IO.puts("💡 RECOMMENDATIONS:")
              Enum.with_index(result.recommendations, 1)
              |> Enum.each(fn {rec, index} ->
                IO.puts("   #{index}. [#{String.upcase(rec["type"])}] #{rec["action"]}")
                IO.puts("      Target System: #{String.upcase(rec["system"])}")
                IO.puts("      Rationale: #{rec["rationale"]}")
                IO.puts()
              end)
            end
            
            if length(result.learning_points) > 0 do
              IO.puts("🎓 LEARNING POINTS:")
              Enum.each(result.learning_points, fn point ->
                IO.puts("   • #{point}")
              end)
              IO.puts()
            end
            
            IO.puts("🎉 Live test completed successfully!")
            
          {:error, reason} ->
            IO.puts("❌ Analysis failed: #{inspect(reason)}")
        end
        
      {:error, reason} ->
        IO.puts("❌ Failed to create provider: #{inspect(reason)}")
    end
  end
end

# Run the test
LiveTest.run()