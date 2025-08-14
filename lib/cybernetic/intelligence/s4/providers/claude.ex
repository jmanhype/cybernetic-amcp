defmodule Cybernetic.Intelligence.S4.Providers.Claude do
  @moduledoc """
  Claude API provider for S4 LLM integration.
  Uses Anthropic's Claude API for policy gap analysis and SOP generation.
  """
  @behaviour Cybernetic.Intelligence.S4.Providers.LLMProvider
  
  require Logger
  
  @api_url "https://api.anthropic.com/v1/messages"
  @model "claude-3-5-sonnet-20241022"
  @max_tokens 4096
  
  @impl true
  def complete(prompt, opts \\ []) do
    api_key = opts[:api_key] || System.get_env("ANTHROPIC_API_KEY")
    
    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      request_completion(prompt, api_key, opts)
    end
  end
  
  defp request_completion(prompt, api_key, opts) do
    body = %{
      model: opts[:model] || @model,
      max_tokens: opts[:max_tokens] || @max_tokens,
      messages: [
        %{
          role: "user",
          content: prompt
        }
      ],
      system: """
      You are a VSM System-4 intelligence analyst for a cybernetic control system.
      Your role is to analyze operational facts and identify policy gaps.
      Always respond with valid JSON containing 'sop_updates' and 'risk_score'.
      """
    }
    
    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
    
    case Req.post(@api_url, json: body, headers: headers) do
      {:ok, %{status: 200, body: response}} ->
        parse_response(response)
        
      {:ok, %{status: status, body: body}} ->
        Logger.error("Claude API error: status=#{status}, body=#{inspect(body)}")
        {:error, {:api_error, status, body}}
        
      {:error, reason} ->
        Logger.error("Claude API request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end
  
  defp parse_response(%{"content" => [%{"text" => text} | _]}) do
    # Extract JSON from Claude's response
    case extract_json(text) do
      {:ok, _json} -> {:ok, text}
      {:error, _} -> 
        # If no valid JSON, wrap the response
        json_response = Jason.encode!(%{
          sop_updates: [%{
            action: "review",
            description: text,
            priority: "medium"
          }],
          risk_score: 50
        })
        {:ok, json_response}
    end
  end
  
  defp parse_response(response) do
    Logger.warning("Unexpected Claude response format: #{inspect(response)}")
    {:error, :invalid_response}
  end
  
  defp extract_json(text) do
    # Try to find JSON in the response
    case Regex.run(~r/\{.*\}/s, text) do
      [json_str] -> Jason.decode(json_str)
      _ -> {:error, :no_json}
    end
  end
end