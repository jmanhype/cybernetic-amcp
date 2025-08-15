#!/usr/bin/env elixir

# Quick test of live API providers

# Set environment
System.put_env("OPENAI_API_KEY", "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")

IO.puts("🧪 Quick S4 Multi-Provider API Test")
IO.puts("===================================")

# Test OpenAI API directly
IO.puts("\n🔵 Testing OpenAI API Connection...")

openai_payload = %{
  "model" => "gpt-4o",
  "messages" => [
    %{"role" => "user", "content" => "Generate a brief analysis of implementing multi-provider AI routing in 2 sentences."}
  ],
  "max_tokens" => 100
}

case Jason.encode(openai_payload) do
  {:ok, json} ->
    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{System.get_env("OPENAI_API_KEY")}"}
    ]
    
    case HTTPoison.post("https://api.openai.com/v1/chat/completions", json, headers, timeout: 30_000) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, response} ->
            content = get_in(response, ["choices", Access.at(0), "message", "content"])
            tokens_used = get_in(response, ["usage", "total_tokens"])
            
            IO.puts("✅ OpenAI API: SUCCESS")
            IO.puts("  Response: #{content}")
            IO.puts("  Tokens used: #{tokens_used}")
            
          {:error, _} ->
            IO.puts("❌ OpenAI API: JSON decode failed")
        end
        
      {:ok, %{status: status, body: body}} ->
        IO.puts("❌ OpenAI API: HTTP #{status}")
        IO.puts("  Error: #{body}")
        
      {:error, reason} ->
        IO.puts("❌ OpenAI API: Network error - #{inspect(reason)}")
    end
    
  {:error, _} ->
    IO.puts("❌ OpenAI API: JSON encode failed")
end

# Test Anthropic API if available
IO.puts("\n🟣 Testing Anthropic API Connection...")

if System.get_env("ANTHROPIC_API_KEY") do
  anthropic_payload = %{
    "model" => "claude-3-5-sonnet-20241022",
    "max_tokens" => 100,
    "messages" => [
      %{"role" => "user", "content" => "Explain the benefit of multi-provider AI systems in 2 sentences."}
    ]
  }
  
  case Jason.encode(anthropic_payload) do
    {:ok, json} ->
      headers = [
        {"Content-Type", "application/json"},
        {"x-api-key", System.get_env("ANTHROPIC_API_KEY")},
        {"anthropic-version", "2023-06-01"}
      ]
      
      case HTTPoison.post("https://api.anthropic.com/v1/messages", json, headers, timeout: 30_000) do
        {:ok, %{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, response} ->
              content = get_in(response, ["content", Access.at(0), "text"])
              input_tokens = get_in(response, ["usage", "input_tokens"])
              output_tokens = get_in(response, ["usage", "output_tokens"])
              
              IO.puts("✅ Anthropic API: SUCCESS")
              IO.puts("  Response: #{content}")
              IO.puts("  Tokens: #{input_tokens} input, #{output_tokens} output")
              
            {:error, _} ->
              IO.puts("❌ Anthropic API: JSON decode failed")
          end
          
        {:ok, %{status: status, body: body}} ->
          IO.puts("❌ Anthropic API: HTTP #{status}")
          IO.puts("  Error: #{body}")
          
        {:error, reason} ->
          IO.puts("❌ Anthropic API: Network error - #{inspect(reason)}")
      end
      
    {:error, _} ->
      IO.puts("❌ Anthropic API: JSON encode failed")
  end
else
  IO.puts("⚠️  Anthropic API key not found")
end

IO.puts("\n🏁 API Test Complete")
IO.puts("\nNow the S4 Multi-Provider system can route between these live providers!")