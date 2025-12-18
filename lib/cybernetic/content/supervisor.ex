defmodule Cybernetic.Content.Supervisor do
  @moduledoc """
  Supervisor for Content layer processes.

  Manages:
  - SemanticContainer - Content storage with embeddings
  - Ingest Pipeline - Content processing
  - CBCP - Bucket management

  Connectors are started on-demand, not supervised here.
  """

  use Supervisor

  require Logger

  @doc "Start the Content supervisor"
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Logger.info("Content Supervisor starting")

    children = [
      # Semantic Container for content storage
      {Cybernetic.Content.SemanticContainer, container_opts(opts)},

      # CBCP for bucket management
      {Cybernetic.Content.Buckets.CBCP, cbcp_opts(opts)},

      # Ingest Pipeline for content processing
      {Cybernetic.Content.Pipeline.Ingest, pipeline_opts(opts)}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
  end

  @doc "Get health status of Content subsystem"
  @spec health_check() :: :ok | {:error, term()}
  def health_check do
    children = [
      Cybernetic.Content.SemanticContainer,
      Cybernetic.Content.Buckets.CBCP,
      Cybernetic.Content.Pipeline.Ingest
    ]

    failed =
      Enum.reject(children, fn child ->
        case Process.whereis(child) do
          nil -> false
          pid -> Process.alive?(pid)
        end
      end)

    if Enum.empty?(failed) do
      :ok
    else
      {:error, {:unhealthy_children, failed}}
    end
  end

  # Private

  defp container_opts(opts) do
    hnsw_index = Keyword.get(opts, :hnsw_index)

    [
      name: Cybernetic.Content.SemanticContainer,
      hnsw_index: hnsw_index
    ]
  end

  defp cbcp_opts(opts) do
    container_server = Keyword.get(opts, :container_server, Cybernetic.Content.SemanticContainer)

    [
      name: Cybernetic.Content.Buckets.CBCP,
      container_server: container_server
    ]
  end

  defp pipeline_opts(opts) do
    container_server = Keyword.get(opts, :container_server, Cybernetic.Content.SemanticContainer)

    [
      name: Cybernetic.Content.Pipeline.Ingest,
      container_server: container_server
    ]
  end
end
