defmodule Cybernetic.VSM.System4.Providers.ReqLLMProvider do
  @moduledoc """
  Unified LLM provider using req_llm pipeline.

  Implements the standard LLMProvider behaviour but delegates all operations
  to the composable pipeline, providing centralized retries, telemetry, etc.
  """

  @behaviour Cybernetic.VSM.System4.LLMProvider

  alias Cybernetic.VSM.System4.LLM.Pipeline
  require Logger

  @impl true
  def capabilities do
    %{
      modes: [:chat, :completion, :reasoning, :tool_use, :json],
      strengths: [:unified, :extensible, :reliable],
      # Varies by provider, but req_llm handles limits
      max_tokens: 128_000,
      # Max context across all providers
      context_window: 1_000_000
    }
  end

  @impl true
  def analyze_episode(episode, opts \\ []) do
    ctx = %{
      op: :analyze,
      episode: episode,
      stream?: opts[:stream?] || false,
      policy: extract_policy(opts),
      params: extract_params(opts),
      meta: %{
        request_id: opts[:request_id],
        caller: opts[:caller] || self()
      }
    }

    case Pipeline.run(ctx) do
      {:ok, result} ->
        format_analyze_response(result)

      {:error, reason} ->
        Logger.error("ReqLLMProvider.analyze_episode failed: #{inspect(reason)}")
        {:error, reason}

      stream when is_struct(stream, Stream) or is_function(stream, 2) ->
        # Return streaming response as-is
        stream
    end
  end

  @impl true
  def generate(prompt, opts \\ []) do
    ctx = build_generate_context(prompt, opts)

    case Pipeline.run(ctx) do
      {:ok, result} ->
        format_generate_response(result)

      {:error, reason} ->
        Logger.error("ReqLLMProvider.generate failed: #{inspect(reason)}")
        {:error, reason}

      stream when is_struct(stream, Stream) or is_function(stream, 2) ->
        stream
    end
  end

  @impl true
  def embed(text, opts \\ []) do
    # Embedding support would need separate pipeline or req_llm extension
    # For now, return error as req_llm may not support all embedding models
    Logger.warning("ReqLLMProvider.embed not yet implemented")
    {:error, :not_implemented}
  end

  @impl true
  def health_check do
    # Simple health check - try a minimal request
    ctx = %{
      op: :health_check,
      messages: [%{role: "user", content: "ping"}],
      stream?: false,
      params: %{max_tokens: 1},
      policy: %{force_provider: :anthropic, force_model: "claude-3-5-sonnet-20241022"}
    }

    case Pipeline.run(ctx) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Additional method for chat operations (common pattern)
  def chat(messages, opts \\ []) do
    ctx = %{
      op: :chat,
      messages: messages,
      stream?: opts[:stream?] || false,
      policy: extract_policy(opts),
      params: extract_params(opts),
      meta: %{
        request_id: opts[:request_id],
        caller: opts[:caller] || self()
      }
    }

    case Pipeline.run(ctx) do
      {:ok, result} ->
        format_chat_response(result)

      {:error, reason} ->
        Logger.error("ReqLLMProvider.chat failed: #{inspect(reason)}")
        {:error, reason}

      stream when is_struct(stream, Stream) or is_function(stream, 2) ->
        stream
    end
  end

  # Private helpers

  defp build_generate_context(prompt, opts) when is_binary(prompt) do
    %{
      op: :generate,
      messages: [%{role: "user", content: prompt}],
      stream?: opts[:stream?] || false,
      policy: extract_policy(opts),
      params: extract_params(opts),
      meta: %{
        request_id: opts[:request_id],
        caller: opts[:caller] || self()
      }
    }
  end

  defp build_generate_context(messages, opts) when is_list(messages) do
    %{
      op: :generate,
      messages: messages,
      stream?: opts[:stream?] || false,
      policy: extract_policy(opts),
      params: extract_params(opts),
      meta: %{
        request_id: opts[:request_id],
        caller: opts[:caller] || self()
      }
    }
  end

  defp extract_policy(opts) do
    # Provider can come from router or be explicitly specified
    provider = opts[:provider]
    model = opts[:model]

    %{}
    |> maybe_add_policy(:force_provider, provider)
    |> maybe_add_policy(:force_model, model)
    |> maybe_add_policy(:budget, opts[:budget])
    |> maybe_add_policy(:timeout_ms, opts[:timeout])
  end

  defp maybe_add_policy(policy, _key, nil), do: policy
  defp maybe_add_policy(policy, key, value), do: Map.put(policy, key, value)

  defp extract_params(opts) do
    %{}
    |> maybe_add_param(:temperature, opts[:temperature])
    |> maybe_add_param(:max_tokens, opts[:max_tokens])
    |> maybe_add_param(:top_p, opts[:top_p])
    |> maybe_add_param(:frequency_penalty, opts[:frequency_penalty])
    |> maybe_add_param(:presence_penalty, opts[:presence_penalty])
    |> maybe_add_param(:tools, opts[:tools])
    |> maybe_add_param(:tool_choice, opts[:tool_choice])
    |> maybe_add_param(:response_format, opts[:response_format])
    |> maybe_add_param(:extra, opts[:extra])
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: Map.put(params, key, value)

  defp format_analyze_response(result) do
    {:ok,
     %{
       text: result[:text] || "",
       tokens: result[:tokens] || %{input: 0, output: 0},
       usage: result[:usage] || %{},
       citations: result[:citations] || [],
       confidence: result[:confidence] || 0.8,
       episode_metadata: result[:episode_metadata]
     }}
  end

  defp format_generate_response(result) do
    {:ok,
     %{
       text: result[:text] || "",
       tokens: result[:tokens] || %{input: 0, output: 0},
       usage: result[:usage] || %{},
       tool_calls: result[:tool_calls] || [],
       finish_reason: result[:finish_reason] || :stop
     }}
  end

  defp format_chat_response(result) do
    {:ok,
     %{
       text: result[:text] || "",
       tokens: result[:tokens] || %{input: 0, output: 0},
       usage: result[:usage] || %{},
       tool_calls: result[:tool_calls] || [],
       finish_reason: result[:finish_reason] || :stop,
       role: "assistant"
     }}
  end
end
