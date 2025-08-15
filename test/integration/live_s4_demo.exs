defmodule LiveS4Demo do
  @moduledoc """
  Live demonstration of S4 Multi-Provider Intelligence Hub with real API calls.
  """
  
  alias Cybernetic.VSM.System4.{Episode, Service}
  alias Cybernetic.VSM.System4.Providers.{Anthropic, OpenAI}
  alias Cybernetic.VSM.System3.RateLimiter
  
  require Logger
  
  def run do
    Logger.info("🚀 Live S4 Multi-Provider Intelligence Hub Demonstration")
    Logger.info("=====================================================")
    
    # Test provider health first
    test_provider_health()
    
    # Test budget system
    test_budget_management()
    
    # Run live analysis with different episode types
    test_live_analysis()
    
    Logger.info("✅ Live S4 demonstration completed successfully!")
  end
  
  defp test_provider_health do
    Logger.info("\n🏥 Testing Live Provider Health")
    Logger.info("================================")
    
    # Test Anthropic
    case Anthropic.health_check() do
      :ok -> 
        Logger.info("✅ Anthropic: Healthy and ready")
      {:error, reason} -> 
        Logger.warning("⚠️  Anthropic: #{inspect(reason)}")
    end
    
    # Test OpenAI
    case OpenAI.health_check() do
      :ok -> 
        Logger.info("✅ OpenAI: Healthy and ready")
      {:error, reason} -> 
        Logger.warning("⚠️  OpenAI: #{inspect(reason)}")
    end
  end
  
  defp test_budget_management do
    Logger.info("\n💰 Testing Budget Management")
    Logger.info("=============================")
    
    # Reset budget for clean test
    :ok = RateLimiter.reset_budget(:s4_llm)
    
    # Check initial status
    status = RateLimiter.budget_status(:s4_llm)
    Logger.info("Initial budget: #{status.remaining}/#{status.limit} tokens available")
    
    # Request some tokens
    case RateLimiter.request_tokens(:s4_llm, :analysis, :high) do
      :ok -> Logger.info("✅ Budget request approved (high priority)")
      {:error, reason} -> Logger.warning("❌ Budget request denied: #{reason}")
    end
    
    # Check status after
    final_status = RateLimiter.budget_status(:s4_llm)
    Logger.info("After request: #{final_status.remaining}/#{final_status.limit} tokens remaining")
  end
  
  defp test_live_analysis do
    Logger.info("\n🤖 Testing Live AI Analysis")
    Logger.info("=============================")
    
    # Create test episodes
    episodes = [
      create_episode(:policy_review, %{
        title: "Critical Security Policy Review",
        data: %{
          policy_type: "data_access",
          violation_severity: "high",
          affected_systems: ["user_database", "payment_processor"],
          compliance_frameworks: ["SOC2", "PCI-DSS"]
        },
        context: %{
          incident_count: 3,
          business_impact: "critical",
          regulatory_deadline: "2024-02-01"
        }
      }),
      
      create_episode(:code_gen, %{
        title: "Generate Secure API Authentication",
        data: %{
          language: "elixir",
          framework: "phoenix",
          requirements: ["JWT validation", "role-based access", "rate limiting"],
          security_level: "high"
        },
        context: %{
          existing_auth: "basic",
          user_base: "enterprise",
          compliance_required: true
        }
      })
    ]
    
    # Analyze each episode
    for episode <- episodes do
      Logger.info("\n📋 Analyzing Episode: #{episode.title}")
      Logger.info("Episode Type: #{episode.kind}")
      
      case Service.analyze(episode) do
        {:ok, analysis} ->
          Logger.info("✅ Analysis completed successfully")
          Logger.info("  Provider: #{get_likely_provider(episode.kind)}")
          Logger.info("  Analysis length: #{String.length(analysis.text)} characters")
          Logger.info("  Input tokens: #{analysis.tokens.input}")
          Logger.info("  Output tokens: #{analysis.tokens.output}")
          Logger.info("  Cost: $#{Float.round(analysis.usage.cost_usd, 4)}")
          Logger.info("  Latency: #{analysis.usage.latency_ms}ms")
          Logger.info("  Confidence: #{analysis.confidence}")
          Logger.info("  SOP suggestions: #{length(analysis.sop_suggestions)}")
          Logger.info("  Recommendations: #{length(analysis.recommendations)}")
          
          # Show first few lines of analysis
          preview = analysis.text
          |> String.split("\n")
          |> Enum.take(3)
          |> Enum.join(" ")
          |> String.slice(0, 150)
          
          Logger.info("  Preview: #{preview}...")
          
          # Show SOP suggestions
          if length(analysis.sop_suggestions) > 0 do
            Logger.info("  📋 SOP Suggestions:")
            for sop <- Enum.take(analysis.sop_suggestions, 2) do
              Logger.info("    • #{sop["title"]} (#{sop["priority"]})")
            end
          end
          
        {:error, reason} ->
          Logger.error("❌ Analysis failed: #{inspect(reason)}")
      end
      
      # Small delay between requests
      :timer.sleep(1000)
    end
  end
  
  defp create_episode(kind, attrs) do
    %Episode{
      id: UUID.uuid4() |> to_string(),
      kind: kind,
      title: attrs.title,
      priority: :high,
      source_system: :s1,
      created_at: DateTime.utc_now(),
      context: attrs.context,
      data: attrs.data,
      metadata: %{live_demo: true, timestamp: DateTime.utc_now()}
    }
  end
  
  defp get_likely_provider(:policy_review), do: "Anthropic (reasoning focus)"
  defp get_likely_provider(:code_gen), do: "OpenAI (code generation focus)"
  defp get_likely_provider(:root_cause), do: "Anthropic (systems thinking)"
  defp get_likely_provider(:anomaly_detection), do: "Anthropic (analysis focus)"
  defp get_likely_provider(_), do: "Multi-provider"
end

# Set environment variable
System.put_env("OPENAI_API_KEY", "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")

# Run the demo
LiveS4Demo.run()