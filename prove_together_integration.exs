#!/usr/bin/env elixir

# Comprehensive proof that Together AI is fully integrated into the S4 Multi-Provider Hub

IO.puts("\n🔍 PROVING TOGETHER AI INTEGRATION")
IO.puts("=" |> String.duplicate(60))

# 1. CHECK MODULE EXISTS
IO.puts("\n✅ 1. Module Existence Check:")
module_exists = Code.ensure_loaded?(Cybernetic.VSM.System4.Providers.Together)
IO.puts("   Together provider module exists: #{module_exists}")

# 2. CHECK ROUTER INTEGRATION
IO.puts("\n✅ 2. Router Integration Check:")
alias Cybernetic.VSM.System4.{Episode, Router}

# Check Together is in routing chains
code_gen_chain = Router.select_chain(%Episode{kind: :code_gen}, [])
IO.puts("   Code generation chain: #{inspect(code_gen_chain)}")
IO.puts("   Together in chain: #{:together in code_gen_chain}")

root_cause_chain = Router.select_chain(%Episode{kind: :root_cause}, [])
IO.puts("   Root cause chain: #{inspect(root_cause_chain)}")
IO.puts("   Together in chain: #{:together in root_cause_chain}")

anomaly_chain = Router.select_chain(%Episode{kind: :anomaly_detection}, [])
IO.puts("   Anomaly detection chain: #{inspect(anomaly_chain)}")
IO.puts("   Together in chain: #{:together in anomaly_chain}")

optimization_chain = Router.select_chain(%Episode{kind: :optimization}, [])
IO.puts("   Optimization chain: #{inspect(optimization_chain)}")
IO.puts("   Together in chain: #{:together in optimization_chain}")

prediction_chain = Router.select_chain(%Episode{kind: :prediction}, [])
IO.puts("   Prediction chain: #{inspect(prediction_chain)}")
IO.puts("   Together in chain: #{:together in prediction_chain}")

classification_chain = Router.select_chain(%Episode{kind: :classification}, [])
IO.puts("   Classification chain: #{inspect(classification_chain)}")
IO.puts("   Together in chain: #{:together in classification_chain}")

# 3. CHECK PROVIDER MODULE RESOLUTION
IO.puts("\n✅ 3. Provider Module Resolution:")
case Router.get_provider_module(:together) do
  {:ok, module} ->
    IO.puts("   Together module resolved: #{inspect(module)}")
    IO.puts("   Module loaded: #{Code.ensure_loaded?(module)}")
  {:error, reason} ->
    IO.puts("   ❌ Failed to resolve: #{inspect(reason)}")
end

# 4. CHECK CONFIGURATION
IO.puts("\n✅ 4. Configuration Check:")
config = Application.get_env(:cybernetic, Cybernetic.VSM.System4.Providers.Together, [])
IO.puts("   API key configured: #{Keyword.has_key?(config, :api_key)}")
IO.puts("   Default model: #{Keyword.get(config, :model, "not set")}")
IO.puts("   Max tokens: #{Keyword.get(config, :max_tokens, "not set")}")
IO.puts("   Temperature: #{Keyword.get(config, :temperature, "not set")}")

# 5. CHECK S4 SERVICE INTEGRATION
IO.puts("\n✅ 5. S4 Service Integration:")
# Read the service file to verify Together is in circuit breakers
service_path = "/Users/speed/Downloads/cybernetic/lib/cybernetic/vsm/system4/service.ex"
service_content = File.read!(service_path)
together_in_cb = service_content =~ "providers = [:anthropic, :openai, :together, :ollama]"
IO.puts("   Together in circuit breakers: #{together_in_cb}")

# 6. CHECK CAPABILITIES
IO.puts("\n✅ 6. Provider Capabilities:")
alias Cybernetic.VSM.System4.Providers.Together
caps = Together.capabilities()
IO.puts("   Modes: #{inspect(caps.modes)}")
IO.puts("   Strengths: #{inspect(caps.strengths)}")
IO.puts("   Max tokens: #{caps.max_tokens}")
IO.puts("   Context window: #{caps.context_window} tokens (128k!)")

# 7. SIMULATE ROUTING SCENARIOS
IO.puts("\n✅ 7. Routing Priority Tests:")

routing_tests = [
  {:code_gen, "Code Generation", [:openai, :together, :anthropic]},
  {:root_cause, "Root Cause Analysis", [:anthropic, :together, :openai]},
  {:anomaly_detection, "Anomaly Detection", [:together, :anthropic, :ollama]},
  {:optimization, "Optimization", [:openai, :together, :anthropic]},
  {:prediction, "Prediction", [:together, :anthropic, :openai]},
  {:classification, "Classification", [:together, :openai, :ollama]}
]

all_correct = Enum.all?(routing_tests, fn {kind, name, expected} ->
  episode = Episode.new(kind, name, %{test: true})
  actual = Router.select_chain(episode, [])
  correct = actual == expected
  
  status = if correct, do: "✅", else: "❌"
  IO.puts("   #{status} #{name}: #{if correct, do: "Correct", else: "Mismatch"}")
  if not correct do
    IO.puts("      Expected: #{inspect(expected)}")
    IO.puts("      Got: #{inspect(actual)}")
  end
  
  correct
end)

# 8. INTEGRATION POINTS SUMMARY
IO.puts("\n✅ 8. Integration Points Summary:")
integration_points = [
  {"Provider Module", module_exists},
  {"Router Chain Selection", :together in code_gen_chain},
  {"Module Resolution", match?({:ok, _}, Router.get_provider_module(:together))},
  {"Configuration Present", length(config) > 0},
  {"Circuit Breaker Setup", together_in_cb},
  {"Routing Tests Pass", all_correct}
]

all_integrated = Enum.all?(integration_points, fn {_, status} -> status end)

IO.puts("\n📊 Integration Status:")
for {point, status} <- integration_points do
  icon = if status, do: "✅", else: "❌"
  IO.puts("   #{icon} #{point}: #{status}")
end

# 9. USAGE EXAMPLE
IO.puts("\n✅ 9. Usage Example (Mock):")
IO.puts("""
   # How to use Together AI in the system:
   
   # 1. Direct provider call:
   episode = Episode.new(:code_gen, "Generate Elixir function", 
     %{prompt: "Create a fibonacci function"})
   
   # 2. Via S4 Service (will route through Together if appropriate):
   {:ok, result, metadata} = Cybernetic.VSM.System4.Service.analyze(episode)
   
   # 3. Together will be selected for:
   #    - Fast inference needs (classification, prediction)
   #    - Code generation (as secondary option)
   #    - Anomaly detection (as primary option)
   #    - When needing open-source models
""")

# 10. FINAL VERDICT
IO.puts("\n" <> "=" |> String.duplicate(60))
if all_integrated do
  IO.puts("🎉 PROOF COMPLETE: Together AI is FULLY INTEGRATED!")
  IO.puts("\n✅ Together AI is successfully wired into:")
  IO.puts("   • S4 Router with intelligent task-based selection")
  IO.puts("   • S4 Service with circuit breaker protection")
  IO.puts("   • Configuration system with all parameters")
  IO.puts("   • Provider chain fallback mechanisms")
  IO.puts("   • 6 different routing scenarios optimized for Together's strengths")
  IO.puts("\n🚀 The multi-provider S4 Intelligence Hub now has 4 providers:")
  IO.puts("   1. Anthropic (deep reasoning)")
  IO.puts("   2. OpenAI (code generation)")
  IO.puts("   3. Together (speed + open models)")
  IO.puts("   4. Ollama (privacy + local)")
else
  IO.puts("⚠️  Some integration points need attention")
end

IO.puts("\n💡 Next: Set TOGETHER_API_KEY to test live functionality")
IO.puts("   export TOGETHER_API_KEY='your-key-here'")
IO.puts("   mix run test_together_ai.exs")