defmodule Cybernetic.Intelligence.Embeddings do
  @moduledoc """
  The single embedding design parameter (DP) for the whole system.

  Before this module existed (Axiomatic Design coupling register #4/#5,
  Issue #86), three subsystems each generated their own counterfeit
  embeddings:

  - `Cybernetic.Capabilities.Registry` hashed text with SHA-256 and
    dressed the bytes up as a 16-dimension vector.
  - `Cybernetic.Content.SemanticContainer` fell back to the same
    hash-expansion trick whenever ReqLLM was unavailable.
  - `Cybernetic.VSM.System4.Memory` generated 768 *random* floats per
    query and never actually compared them to anything.

  All three now delegate here. This module calls a real embedding
  provider — the same `embed/2` implementations the S4 LLM providers
  already expose — and normalizes their result shapes to a plain
  `{:ok, [float()]}`.

  ## No pseudo fallback

  If the configured provider is unreachable or returns an error, that
  error is returned to the caller. This module will never fabricate a
  hash-based or random vector: a fake embedding is worse than no
  embedding, because every downstream similarity score computed from it
  is meaningless while looking meaningful. Callers decide how to
  degrade (skip indexing, keyword fallback, empty result set).

  ## Configuration

      config :cybernetic, :embeddings,
        provider: :ollama,
        model: "nomic-embed-text",
        dimensions: 768

  `provider` is `:ollama` (default, local, no API key), `:openai`, or
  any module implementing `embed(text, opts)` — the module form is the
  seam tests use to inject a deterministic provider. `model` is passed
  through to the provider only when set; provider defaults apply
  otherwise. Per-call `opts` (`provider:`, `model:`) override config.
  """

  alias Cybernetic.VSM.System4.Providers.{Ollama, OpenAI}

  @type provider :: :ollama | :openai | module()

  @doc """
  Embed `text` with the configured provider.

  Returns `{:ok, embedding}` with the provider's vector as a list of
  floats, or `{:error, reason}` when the provider fails. Provider
  errors are propagated unchanged — never replaced with a fabricated
  vector.
  """
  @spec embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text) do
    config = Application.get_env(:cybernetic, :embeddings, [])
    provider = Keyword.get(opts, :provider) || Keyword.get(config, :provider, :ollama)
    model = Keyword.get(opts, :model) || Keyword.get(config, :model)

    provider_opts = if model, do: [model: model], else: []

    case provider_module(provider) do
      {:ok, module} ->
        module
        |> apply(:embed, [text, provider_opts])
        |> normalize_result()

      {:error, _} = error ->
        error
    end
  end

  @spec provider_module(provider()) ::
          {:ok, module()} | {:error, {:unknown_embedding_provider, term()}}
  defp provider_module(:ollama), do: {:ok, Ollama}
  defp provider_module(:openai), do: {:ok, OpenAI}

  defp provider_module(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :embed, 2) do
      {:ok, module}
    else
      {:error, {:unknown_embedding_provider, module}}
    end
  end

  defp provider_module(other), do: {:error, {:unknown_embedding_provider, other}}

  # Providers return {:ok, %{embeddings: vector, dimensions: n, usage: _}}
  # (note: the S4 providers use the plural key `embeddings` for a single
  # vector). Accept that shape plus the plainer variants so new
  # providers and test doubles do not have to match it exactly.
  @spec normalize_result(term()) :: {:ok, [float()]} | {:error, term()}
  defp normalize_result({:ok, vector}) when is_list(vector), do: {:ok, vector}
  defp normalize_result({:ok, %{embedding: vector}}) when is_list(vector), do: {:ok, vector}
  defp normalize_result({:ok, %{embeddings: vector}}) when is_list(vector), do: {:ok, vector}
  defp normalize_result({:ok, %{"embedding" => vector}}) when is_list(vector), do: {:ok, vector}
  defp normalize_result({:ok, %{"embeddings" => vector}}) when is_list(vector), do: {:ok, vector}
  defp normalize_result({:error, _reason} = error), do: error

  defp normalize_result(other), do: {:error, {:unexpected_embedding_response, other}}
end
