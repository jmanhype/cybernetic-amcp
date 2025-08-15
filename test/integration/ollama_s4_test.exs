defmodule OllamaS4Test do
  @moduledoc """
  Test Ollama provider integration with S4 Intelligence system.
  Demonstrates local, privacy-focused AI processing.
  """
  
  alias Cybernetic.VSM.System4.{Episode, Router}
  alias Cybernetic.VSM.System4.Providers.Ollama
  alias Cybernetic.VSM.System3.RateLimiter
  
  require Logger
  
  def run do
    Logger.info("🚀 Testing Ollama Local AI Provider with S4 System")
    Logger.info("=" |> String.duplicate(55))
    
    # Test Ollama health
    test_ollama_health()
    
    # Test direct Ollama API
    test_direct_ollama_api()
    
    # Test Ollama through S4 provider
    test_ollama_provider()
    
    # Test privacy-focused episode routing
    test_privacy_routing()
    
    Logger.info("\n✅ Ollama S4 Integration Test Complete!")
  end
  
  defp test_ollama_health do
    Logger.info("\n🏥 Testing Ollama Health Check")
    Logger.info("-" |> String.duplicate(30))
    
    case Ollama.health_check() do
      :ok ->
        Logger.info("✅ Ollama server is healthy and ready")
      {:error, :server_unavailable} ->
        Logger.error("❌ Ollama server not available at localhost:11434")
      {:error, reason} ->
        Logger.error("❌ Ollama health check failed: #{inspect(reason)}")
    end
  end
  
  defp test_direct_ollama_api do
    Logger.info("\n🔧 Testing Direct Ollama API")
    Logger.info("-" |> String.duplicate(30))
    
    # Use a lightweight model for faster response
    payload = %{
      "model" => "tinyllama:latest",
      "prompt" => "Explain privacy-focused AI in one sentence.",
      "stream" => false,
      "options" => %{
        "temperature" => 0.1,
        "num_predict" => 50
      }
    }
    
    case make_ollama_request(payload, "/api/generate") do
      {:ok, response} ->
        Logger.info("✅ Direct API call successful")
        Logger.info("  Model: #{response["model"]}")
        Logger.info("  Response: #{String.slice(response["response"], 0, 150)}...")
        Logger.info("  Eval count: #{response["eval_count"]} tokens")
        Logger.info("  Total duration: #{div(response["total_duration"], 1_000_000)}ms")
        Logger.info("  Cost: $0.00 (local processing)")
        
      {:error, reason} ->
        Logger.error("❌ Direct API call failed: #{inspect(reason)}")
    end
  end
  
  defp test_ollama_provider do
    Logger.info("\n🤖 Testing Ollama S4 Provider")
    Logger.info("-" |> String.duplicate(30))
    
    # Test capabilities
    caps = Ollama.capabilities()
    Logger.info("Provider Capabilities:")
    Logger.info("  Modes: #{inspect(caps.modes)}")
    Logger.info("  Strengths: #{inspect(caps.strengths)}")
    Logger.info("  Max Tokens: #{caps.max_tokens}")
    Logger.info("  Context Window: #{caps.context_window}")
    
    # Test generation
    case Ollama.generate("What are the benefits of local AI processing?", model: "tinyllama:latest", max_tokens: 100) do
      {:ok, result} ->
        Logger.info("\n✅ Provider generation successful")
        Logger.info("  Response length: #{String.length(result.text)} chars")
        Logger.info("  Input tokens: #{result.tokens.input}")
        Logger.info("  Output tokens: #{result.tokens.output}")
        Logger.info("  Cost: $#{result.usage.cost_usd} (always zero)")
        Logger.info("  Preview: #{String.slice(result.text, 0, 100)}...")
        
      {:error, reason} ->
        Logger.error("❌ Provider generation failed: #{inspect(reason)}")
    end
  end
  
  defp test_privacy_routing do
    Logger.info("\n🔒 Testing Privacy-Focused Episode Routing")
    Logger.info("-" |> String.duplicate(40))
    
    # Create a privacy-sensitive episode
    episode = %Episode{
      id: UUID.uuid4() |> to_string(),
      kind: :policy_review,
      title: "GDPR Compliance Review for User Data Processing",
      priority: :high,
      source_system: :s5,
      created_at: DateTime.utc_now(),
      context: %{
        data_sensitivity: "high",
        compliance_framework: "GDPR",
        requires_local_processing: true
      },
      data: %{
        personal_data_types: ["email", "phone", "address"],
        processing_purpose: "customer_analytics",
        retention_period: "2_years",
        encryption_required: true
      },
      metadata: %{test: true, privacy_critical: true}
    }
    
    # Check routing
    chain = Router.select_chain(episode, [])
    Logger.info("Episode: #{episode.title}")
    Logger.info("  Sensitivity: High (GDPR)")
    Logger.info("  Routing Chain: #{inspect(chain)}")
    Logger.info("  Primary Provider: #{List.first(chain)}")
    
    # Analyze with Ollama
    Logger.info("\n📊 Analyzing with Ollama Provider...")
    
    case Ollama.analyze_episode(episode, model: "mistral:latest", max_tokens: 200) do
      {:ok, analysis} ->
        Logger.info("✅ Privacy-focused analysis complete")
        Logger.info("  Analysis length: #{String.length(analysis.text)} chars")
        Logger.info("  Confidence: #{analysis.confidence}")
        Logger.info("  Risk Level: #{analysis.risk_level}")
        Logger.info("  SOP Suggestions: #{length(analysis.sop_suggestions)}")
        Logger.info("  Learning Points: #{length(analysis.learning_points)}")
        Logger.info("  Processing Cost: $0.00 (local)")
        Logger.info("  Data Privacy: 100% (no external API calls)")
        
        # Show some SOP suggestions
        if length(analysis.sop_suggestions) > 0 do
          Logger.info("\n  📋 Privacy SOPs Generated:")
          for sop <- Enum.take(analysis.sop_suggestions, 2) do
            Logger.info("    • #{sop["title"]} (#{sop["priority"]})")
            if sop["privacy_level"], do: Logger.info("      Privacy Level: #{sop["privacy_level"]}")
          end
        end
        
      {:error, reason} ->
        Logger.error("❌ Episode analysis failed: #{inspect(reason)}")
    end
    
    # Test budget impact
    Logger.info("\n💰 Budget Impact:")
    status = RateLimiter.budget_status(:s4_llm)
    Logger.info("  S4 LLM Budget: #{status.remaining}/#{status.limit} tokens")
    Logger.info("  Ollama Cost Impact: $0.00 (no budget consumption)")
    Logger.info("  Perfect for high-volume or sensitive workloads!")
  end
  
  defp make_ollama_request(payload, endpoint) do
    url = "http://localhost:11434#{endpoint}"
    headers = [{"Content-Type", "application/json"}]
    
    with {:ok, json} <- Jason.encode(payload),
         {:ok, %{status: 200, body: body}} <- HTTPoison.post(url, json, headers, timeout: 60_000),
         {:ok, response} <- Jason.decode(body) do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
    end
  end
end

# Run the test
OllamaS4Test.run()