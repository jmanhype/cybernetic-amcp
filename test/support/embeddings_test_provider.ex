defmodule Cybernetic.TestSupport.EmbeddingsProvider do
  @moduledoc """
  Deterministic embedding provider for tests ONLY.

  Produces bag-of-words vectors: each downcased word is hashed into one
  of #{64} buckets, counts are accumulated, and the result is
  L2-normalized. Texts that share words therefore get a higher cosine
  similarity than disjoint texts, which is the one semantic property
  the wiring tests need. This is a test fixture, not a production
  embedding source — production goes through
  `Cybernetic.Intelligence.Embeddings` with a real provider.
  """

  @dimensions 64

  @doc "Number of dimensions produced by this provider."
  @spec dimensions() :: pos_integer()
  def dimensions, do: @dimensions

  @doc "Embed text into a deterministic bag-of-words vector."
  @spec embed(String.t(), keyword()) :: {:ok, [float()]}
  def embed(text, _opts \\ []) do
    counts =
      text
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/, trim: true)
      |> Enum.reduce(%{}, fn word, acc ->
        bucket = :erlang.phash2(word, @dimensions)
        Map.update(acc, bucket, 1.0, &(&1 + 1.0))
      end)

    vector = Enum.map(0..(@dimensions - 1), fn i -> Map.get(counts, i, 0.0) end)
    {:ok, normalize(vector)}
  end

  defp normalize(vector) do
    magnitude = :math.sqrt(Enum.sum(Enum.map(vector, fn x -> x * x end)))

    if magnitude == 0.0 do
      vector
    else
      Enum.map(vector, fn x -> x / magnitude end)
    end
  end
end
