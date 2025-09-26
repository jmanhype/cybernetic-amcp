defmodule Cybernetic.VSM.System4.LLM.Pipeline.Steps.Router do
  @moduledoc """
  Select the provider and model based on policy, episode kind, and availability.
  """

  require Logger

  @default_provider :anthropic
  @default_model "claude-3-5-sonnet-20241022"

  @doc """
  Determine routing based on policy and context.
  
  Sets `:route` in context with provider and model information.
  """
  def run(ctx) do
    route = select_route(ctx)
    
    Logger.info("Routing to provider: #{route.provider}, model: #{route.model}")
    
    {:ok, Map.put(ctx, :route, route)}
  end

  defp select_route(%{policy: %{force_provider: provider, force_model: model}}) 
    when not is_nil(provider) and not is_nil(model) do
    %{
      provider: provider,
      model: format_model_name(provider, model)
    }
  end

  defp select_route(%{episode: %{kind: kind}}) do
    # Route based on episode kind (matching existing logic)
    route_by_kind(kind)
  end

  defp select_route(%{op: op}) do
    # Route based on operation type
    route_by_operation(op)
  end

  defp select_route(_ctx) do
    # Default route
    %{
      provider: @default_provider,
      model: format_model_name(@default_provider, @default_model)
    }
  end

  defp route_by_kind(:policy_review) do
    %{provider: :anthropic, model: format_model_name(:anthropic, "claude-3-5-sonnet-20241022")}
  end

  defp route_by_kind(:code_gen) do
    %{provider: :openai, model: format_model_name(:openai, "gpt-4o")}
  end

  defp route_by_kind(:root_cause) do
    %{provider: :anthropic, model: format_model_name(:anthropic, "claude-3-5-sonnet-20241022")}
  end

  defp route_by_kind(:anomaly_detection) do
    %{provider: :together, model: format_model_name(:together, "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo")}
  end

  defp route_by_kind(:optimization) do
    %{provider: :openai, model: format_model_name(:openai, "gpt-4o")}
  end

  defp route_by_kind(_kind) do
    %{provider: @default_provider, model: format_model_name(@default_provider, @default_model)}
  end

  defp route_by_operation(:analyze) do
    %{provider: :anthropic, model: format_model_name(:anthropic, "claude-3-5-sonnet-20241022")}
  end

  defp route_by_operation(:generate) do
    %{provider: :openai, model: format_model_name(:openai, "gpt-4o")}
  end

  defp route_by_operation(:chat) do
    %{provider: :anthropic, model: format_model_name(:anthropic, "claude-3-5-sonnet-20241022")}
  end

  defp route_by_operation(_op) do
    %{provider: @default_provider, model: format_model_name(@default_provider, @default_model)}
  end

  # Format model names for req_llm compatibility
  defp format_model_name(:anthropic, model) do
    # req_llm expects "anthropic:model-name" format
    if String.contains?(model, ":") do
      model
    else
      "anthropic:#{model}"
    end
  end

  defp format_model_name(:openai, model) do
    if String.contains?(model, ":") do
      model
    else
      "openai:#{model}"
    end
  end

  defp format_model_name(:together, model) do
    # Together models often already have full path
    if String.contains?(model, ":") do
      model
    else
      "together:#{model}"
    end
  end

  defp format_model_name(:ollama, model) do
    if String.contains?(model, ":") do
      model
    else
      "ollama:#{model}"
    end
  end

  defp format_model_name(_provider, model), do: model
end