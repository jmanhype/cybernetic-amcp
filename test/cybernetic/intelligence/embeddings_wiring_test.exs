defmodule Cybernetic.Intelligence.EmbeddingsWiringTest.FailingProvider do
  @moduledoc "Embedding provider that always fails — used to prove errors propagate honestly."
  def embed(_text, _opts), do: {:error, :provider_unavailable}
end

defmodule Cybernetic.Intelligence.EmbeddingsWiringTest.NullStorage do
  @moduledoc """
  In-memory stand-in for the SemanticContainer storage adapter, mirroring
  the canonical Cybernetic.Storage.Adapter contract:
  put(tenant_id, path, content) -> {:ok, artifact} and
  get/delete(tenant_id, path).
  """
  def put(_tenant_id, _path, _content), do: {:ok, %{}}
  def get(_tenant_id, _path), do: {:error, :not_found}
  def delete(_tenant_id, _path), do: :ok
end

defmodule Cybernetic.Intelligence.EmbeddingsWiringTest do
  use ExUnit.Case, async: false

  alias Cybernetic.Capabilities.Registry
  alias Cybernetic.Content.SemanticContainer
  alias Cybernetic.Intelligence.{Embeddings, HNSW}
  alias Cybernetic.TestSupport.EmbeddingsProvider
  alias Cybernetic.VSM.System4.Memory

  alias Cybernetic.Intelligence.EmbeddingsWiringTest.{FailingProvider, NullStorage}

  defp cosine(a, b) do
    dot = Enum.zip(a, b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    ma = :math.sqrt(Enum.sum(Enum.map(a, &(&1 * &1))))
    mb = :math.sqrt(Enum.sum(Enum.map(b, &(&1 * &1))))
    dot / (ma * mb)
  end

  describe "Embeddings.embed/2" do
    test "texts sharing words are closer than disjoint texts" do
      {:ok, query} = Embeddings.embed("ruby gemstone jewelry")
      {:ok, similar} = Embeddings.embed("ruby gemstone jewelry guide")
      {:ok, disjoint} = Embeddings.embed("diesel engine piston repair")

      assert cosine(query, similar) > cosine(query, disjoint)
      assert length(query) == EmbeddingsProvider.dimensions()
    end

    test "provider errors propagate — no fabricated fallback vector" do
      assert {:error, :provider_unavailable} =
               Embeddings.embed("anything", provider: FailingProvider)
    end

    test "an unknown provider is an error, not a vector" do
      assert {:error, {:unknown_embedding_provider, _}} =
               Embeddings.embed("anything", provider: NotARealProvider)
    end
  end

  describe "SemanticContainer + HNSW index" do
    test "stored containers are searchable through the index" do
      index_name = :"hnsw_wiring_#{System.unique_integer([:positive])}"
      container_name = :"semantic_wiring_#{System.unique_integer([:positive])}"

      start_supervised!(
        {HNSW.Index, [name: index_name, dimensions: EmbeddingsProvider.dimensions()]}
      )

      start_supervised!(
        {SemanticContainer,
         [name: container_name, hnsw_index: index_name, storage_adapter: NullStorage]}
      )

      {:ok, ruby} =
        SemanticContainer.create(
          container_name,
          "ruby gemstone jewelry appraisal guide",
          "tenant-a"
        )

      {:ok, _diesel} =
        SemanticContainer.create(
          container_name,
          "diesel engine piston repair manual",
          "tenant-a"
        )

      assert is_list(ruby.embedding)
      assert length(ruby.embedding) == EmbeddingsProvider.dimensions()

      assert {:ok, [{first_id, _distance} | _]} =
               SemanticContainer.search_similar(container_name, "ruby gemstone jewelry")

      assert first_id == ruby.id
    end

    test "without an index the old :hnsw_not_configured error remains explicit" do
      container_name = :"semantic_noindex_#{System.unique_integer([:positive])}"

      start_supervised!({SemanticContainer, [name: container_name, storage_adapter: NullStorage]})

      {:ok, _} = SemanticContainer.create(container_name, "some content", "tenant-a")

      assert {:error, :hnsw_not_configured} =
               SemanticContainer.search_similar(container_name, "some content")
    end
  end

  describe "System4.Memory semantic search" do
    test "ranks the semantically matching entry first" do
      if Process.whereis(Memory) == nil do
        start_supervised!(Memory)
      end

      Memory.clear()
      Memory.store("ep-ruby", :user, "ruby gemstone jewelry appraisal", %{})
      Memory.store("ep-diesel", :user, "diesel engine piston repair", %{})
      # Flush the casts before searching
      _ = Memory.stats()

      assert {:ok, [first | _]} =
               Memory.search("ruby gemstone jewelry", threshold: 0.3)

      assert first.episode_id == "ep-ruby"

      assert {:ok, results} = Memory.search("ruby gemstone jewelry", threshold: 0.3)
      refute Enum.any?(results, &(&1.episode_id == "ep-diesel"))
    end
  end

  describe "Capabilities.Registry discovery" do
    test "discover ranks the matching capability first" do
      start_supervised!(Registry)

      {:ok, ruby} =
        Registry.register(%{
          name: "gem_appraisal",
          description: "Appraises ruby gemstone jewelry",
          provider: GemMod
        })

      {:ok, _diesel} =
        Registry.register(%{
          name: "engine_repair",
          description: "Repairs diesel engine pistons",
          provider: EngineMod
        })

      {:ok, ruby_embedding} = Embeddings.embed("Appraises ruby gemstone jewelry")
      {:ok, diesel_embedding} = Embeddings.embed("Repairs diesel engine pistons")
      :ok = Registry.update_embedding(ruby.id, ruby_embedding)

      {:ok, diesel} = Registry.get_by_name("engine_repair")
      :ok = Registry.update_embedding(diesel.id, diesel_embedding)

      assert {:ok, [first | _]} =
               Registry.discover("ruby gemstone jewelry", threshold: 0.3)

      assert first.name == "gem_appraisal"
    end
  end
end
