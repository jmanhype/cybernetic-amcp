#!/usr/bin/env elixir

Mix.install([
  {:jason, "~> 1.4"},
  {:httpoison, "~> 2.2"}
])

defmodule APIKeyTest do
  def test_key(api_key) do
    url = "https://api.anthropic.com/v1/messages"
    
    # Simple test payload
    payload = %{
      "model" => "claude-3-haiku-20240307",
      "max_tokens" => 10,
      "messages" => [
        %{
          "role" => "user",
          "content" => "Hello"
        }
      ]
    }
    
    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{api_key}"},
      {"anthropic-version", "2023-06-01"}
    ]
    
    case Jason.encode(payload) do
      {:ok, json} ->
        IO.puts("Testing API key...")
        IO.puts("URL: #{url}")
        IO.puts("Payload size: #{byte_size(json)} bytes")
        
        case HTTPoison.post(url, json, headers, timeout: 30_000) do
          {:ok, %{status_code: 200, body: body}} ->
            IO.puts("✅ API key is VALID! Response received.")
            case Jason.decode(body) do
              {:ok, decoded} ->
                IO.puts("Response content: #{inspect(decoded["content"])}")
              {:error, _} ->
                IO.puts("Got response but couldn't decode JSON")
            end
            
          {:ok, %{status_code: 401, body: body}} ->
            IO.puts("❌ API key is INVALID - 401 Unauthorized")
            IO.puts("Error: #{body}")
            
          {:ok, %{status_code: status, body: body}} ->
            IO.puts("⚠️  Unexpected status: #{status}")
            IO.puts("Body: #{body}")
            
          {:error, reason} ->
            IO.puts("❌ Network error: #{inspect(reason)}")
        end
        
      {:error, reason} ->
        IO.puts("❌ JSON encoding error: #{inspect(reason)}")
    end
  end
end

# Test the API key
api_key = "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"

IO.puts("🔑 Testing Anthropic API Key Validity")
IO.puts("=" |> String.duplicate(40))
APIKeyTest.test_key(api_key)