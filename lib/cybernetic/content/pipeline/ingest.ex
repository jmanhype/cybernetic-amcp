defmodule Cybernetic.Content.Pipeline.Ingest do
  @moduledoc """
  Content Ingest Pipeline for processing external content into semantic containers.

  Pipeline stages:
  1. Fetch - Retrieve content from source (HTTP, S3, file)
  2. Normalize - Clean and standardize format
  3. Extract - Extract metadata and entities
  4. Embed - Generate vector embeddings via ReqLLM
  5. Containerize - Wrap in SemanticContainer
  6. Index - Add to HNSW for search

  Supports:
  - Batch processing for multiple items
  - Async processing via Oban jobs
  - Progress tracking and telemetry
  - Retry with exponential backoff
  """

  use GenServer
  require Logger

  alias Cybernetic.Content.SemanticContainer

  # Types
  @type source :: %{
          url: String.t() | nil,
          path: String.t() | nil,
          content: binary() | nil,
          content_type: String.t() | nil
        }

  @type pipeline_result :: %{
          id: String.t(),
          status: :success | :failed | :skipped,
          container_id: String.t() | nil,
          error: term() | nil,
          duration_ms: non_neg_integer()
        }

  @type job :: %{
          id: String.t(),
          source: source(),
          tenant_id: String.t(),
          options: keyword(),
          status: :pending | :processing | :completed | :failed,
          result: pipeline_result() | nil,
          created_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  # Configuration
  @max_concurrent 10
  @fetch_timeout 30_000
  @max_content_size 52_428_800  # 50MB
  @supported_content_types ~w(
    text/plain text/html text/markdown text/csv
    application/json application/xml application/pdf
    image/png image/jpeg image/gif image/webp
  )

  @telemetry [:cybernetic, :content, :pipeline]

  # Client API

  @doc "Start the ingest pipeline server"
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Ingest content from a URL"
  @spec ingest_url(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, pipeline_result()} | {:error, term()}
  def ingest_url(server \\ __MODULE__, url, tenant_id, opts \\ []) do
    source = %{url: url, path: nil, content: nil, content_type: nil}
    ingest(server, source, tenant_id, opts)
  end

  @doc "Ingest content from a file path"
  @spec ingest_file(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, pipeline_result()} | {:error, term()}
  def ingest_file(server \\ __MODULE__, path, tenant_id, opts \\ []) do
    source = %{url: nil, path: path, content: nil, content_type: nil}
    ingest(server, source, tenant_id, opts)
  end

  @doc "Ingest raw content directly"
  @spec ingest_content(GenServer.server(), binary(), String.t(), keyword()) ::
          {:ok, pipeline_result()} | {:error, term()}
  def ingest_content(server \\ __MODULE__, content, tenant_id, opts \\ []) do
    content_type = Keyword.get(opts, :content_type)
    source = %{url: nil, path: nil, content: content, content_type: content_type}
    ingest(server, source, tenant_id, opts)
  end

  @doc "Ingest from a source map"
  @spec ingest(GenServer.server(), source(), String.t(), keyword()) ::
          {:ok, pipeline_result()} | {:error, term()}
  def ingest(server \\ __MODULE__, source, tenant_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(server, {:ingest, source, tenant_id, opts}, timeout)
  end

  @doc "Ingest multiple items in batch"
  @spec ingest_batch(GenServer.server(), [{source(), String.t(), keyword()}], keyword()) ::
          {:ok, [pipeline_result()]}
  def ingest_batch(server \\ __MODULE__, items, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    GenServer.call(server, {:ingest_batch, items, opts}, timeout)
  end

  @doc "Queue an async ingest job (returns immediately)"
  @spec queue_ingest(GenServer.server(), source(), String.t(), keyword()) ::
          {:ok, String.t()}
  def queue_ingest(server \\ __MODULE__, source, tenant_id, opts \\ []) do
    GenServer.call(server, {:queue_ingest, source, tenant_id, opts})
  end

  @doc "Get job status"
  @spec get_job(GenServer.server(), String.t()) :: {:ok, job()} | {:error, :not_found}
  def get_job(server \\ __MODULE__, job_id) do
    GenServer.call(server, {:get_job, job_id})
  end

  @doc "Get pipeline statistics"
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  # Server Implementation

  @impl true
  def init(opts) do
    Logger.info("Ingest Pipeline starting")

    state = %{
      jobs: %{},
      processing: MapSet.new(),
      container_server: Keyword.get(opts, :container_server, SemanticContainer),
      max_concurrent: Keyword.get(opts, :max_concurrent, @max_concurrent),
      stats: %{
        total_ingested: 0,
        total_failed: 0,
        total_bytes: 0,
        avg_duration_ms: 0
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:ingest, source, tenant_id, opts}, _from, state) do
    result = run_pipeline(source, tenant_id, opts, state)
    new_state = update_stats(state, result)
    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call({:ingest_batch, items, _opts}, _from, state) do
    # Process items with limited concurrency
    results =
      items
      |> Task.async_stream(
        fn {source, tenant_id, opts} ->
          run_pipeline(source, tenant_id, opts, state)
        end,
        max_concurrency: state.max_concurrent,
        timeout: @fetch_timeout * 3
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> %{id: nil, status: :failed, error: reason, duration_ms: 0}
      end)

    new_state = Enum.reduce(results, state, &update_stats(&2, &1))
    {:reply, {:ok, results}, new_state}
  end

  @impl true
  def handle_call({:queue_ingest, source, tenant_id, opts}, _from, state) do
    job_id = generate_job_id()
    now = DateTime.utc_now()

    job = %{
      id: job_id,
      source: source,
      tenant_id: tenant_id,
      options: opts,
      status: :pending,
      result: nil,
      created_at: now,
      started_at: nil,
      completed_at: nil
    }

    new_state = %{state | jobs: Map.put(state.jobs, job_id, job)}

    # Process async
    send(self(), {:process_job, job_id})

    {:reply, {:ok, job_id}, new_state}
  end

  @impl true
  def handle_call({:get_job, job_id}, _from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} -> {:reply, {:ok, job}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        pending_jobs: count_jobs_by_status(state, :pending),
        processing_jobs: MapSet.size(state.processing)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:process_job, job_id}, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, %{status: :pending} = job} ->
        if MapSet.size(state.processing) < state.max_concurrent do
          # Process now
          new_state = %{
            state
            | processing: MapSet.put(state.processing, job_id),
              jobs:
                Map.update!(state.jobs, job_id, fn j ->
                  %{j | status: :processing, started_at: DateTime.utc_now()}
                end)
          }

          # Run async
          Task.start(fn ->
            result = run_pipeline(job.source, job.tenant_id, job.options, state)
            send(self(), {:job_completed, job_id, result})
          end)

          {:noreply, new_state}
        else
          # Queue for later
          Process.send_after(self(), {:process_job, job_id}, 1000)
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:job_completed, job_id, result}, state) do
    new_state = %{
      state
      | processing: MapSet.delete(state.processing, job_id),
        jobs:
          Map.update!(state.jobs, job_id, fn j ->
            %{
              j
              | status: if(result.status == :success, do: :completed, else: :failed),
                result: result,
                completed_at: DateTime.utc_now()
            }
          end)
    }

    {:noreply, update_stats(new_state, result)}
  end

  # Pipeline Stages

  @spec run_pipeline(source(), String.t(), keyword(), map()) :: pipeline_result()
  defp run_pipeline(source, tenant_id, opts, state) do
    start_time = System.monotonic_time(:millisecond)
    job_id = generate_job_id()

    result =
      with {:ok, content, content_type} <- stage_fetch(source),
           {:ok, normalized} <- stage_normalize(content, content_type),
           {:ok, metadata} <- stage_extract(normalized, content_type, opts),
           {:ok, container} <- stage_containerize(normalized, tenant_id, metadata, opts, state) do
        emit_telemetry(:success, start_time, %{
          tenant_id: tenant_id,
          content_size: byte_size(normalized)
        })

        %{
          id: job_id,
          status: :success,
          container_id: container.id,
          error: nil,
          duration_ms: System.monotonic_time(:millisecond) - start_time
        }
      else
        {:error, :skipped, reason} ->
          %{
            id: job_id,
            status: :skipped,
            container_id: nil,
            error: reason,
            duration_ms: System.monotonic_time(:millisecond) - start_time
          }

        {:error, reason} ->
          emit_telemetry(:error, start_time, %{tenant_id: tenant_id, reason: reason})

          %{
            id: job_id,
            status: :failed,
            container_id: nil,
            error: reason,
            duration_ms: System.monotonic_time(:millisecond) - start_time
          }
      end

    result
  end

  # Stage 1: Fetch
  @spec stage_fetch(source()) :: {:ok, binary(), String.t()} | {:error, term()}
  defp stage_fetch(%{content: content}) when is_binary(content) and byte_size(content) > 0 do
    content_type = Cybernetic.Storage.ContentType.detect(content, "application/octet-stream")
    {:ok, content, content_type}
  end

  defp stage_fetch(%{path: path}) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        content_type = Cybernetic.Storage.ContentType.from_path(path)
        {:ok, content, content_type}

      {:error, reason} ->
        {:error, {:fetch_failed, reason}}
    end
  end

  defp stage_fetch(%{url: url}) when is_binary(url) do
    fetch_url(url)
  end

  defp stage_fetch(_), do: {:error, :invalid_source}

  @spec fetch_url(String.t()) :: {:ok, binary(), String.t()} | {:error, term()}
  defp fetch_url(url) do
    case Req.get(url, receive_timeout: @fetch_timeout, max_redirects: 3) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        content_type = get_content_type_header(headers)

        if byte_size(body) > @max_content_size do
          {:error, :content_too_large}
        else
          {:ok, body, content_type}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:fetch_failed, reason}}
    end
  end

  @spec get_content_type_header([{String.t(), String.t()}]) :: String.t()
  defp get_content_type_header(headers) do
    headers
    |> Enum.find(fn {k, _v} -> String.downcase(k) == "content-type" end)
    |> case do
      {_, value} -> String.split(value, ";") |> List.first() |> String.trim()
      nil -> "application/octet-stream"
    end
  end

  # Stage 2: Normalize
  @spec stage_normalize(binary(), String.t()) :: {:ok, binary()} | {:error, term()}
  defp stage_normalize(content, content_type) do
    cond do
      String.starts_with?(content_type, "text/html") ->
        {:ok, normalize_html(content)}

      String.starts_with?(content_type, "text/") ->
        {:ok, normalize_text(content)}

      content_type == "application/json" ->
        {:ok, normalize_json(content)}

      content_type in @supported_content_types ->
        {:ok, content}

      true ->
        # Skip unsupported content types
        {:error, :skipped, {:unsupported_content_type, content_type}}
    end
  end

  @spec normalize_html(binary()) :: binary()
  defp normalize_html(html) do
    # Basic HTML to text conversion
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace(~r/&amp;/, "&")
    |> String.replace(~r/&lt;/, "<")
    |> String.replace(~r/&gt;/, ">")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @spec normalize_text(binary()) :: binary()
  defp normalize_text(text) do
    text
    |> String.replace(~r/\r\n/, "\n")
    |> String.replace(~r/\r/, "\n")
    |> String.trim()
  end

  @spec normalize_json(binary()) :: binary()
  defp normalize_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: false)
      {:error, _} -> json
    end
  end

  # Stage 3: Extract metadata
  @spec stage_extract(binary(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp stage_extract(content, content_type, opts) do
    metadata = %{
      content_type: content_type,
      size: byte_size(content),
      word_count: count_words(content),
      extracted_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Add source URL if available
    metadata =
      case Keyword.get(opts, :source_url) do
        nil -> metadata
        url -> Map.put(metadata, :source_url, url)
      end

    # Extract additional metadata based on content type
    metadata =
      if String.starts_with?(content_type, "text/") do
        Map.merge(metadata, extract_text_metadata(content))
      else
        metadata
      end

    {:ok, metadata}
  end

  @spec count_words(binary()) :: non_neg_integer()
  defp count_words(content) do
    content
    |> String.split(~r/\s+/)
    |> Enum.reject(&(&1 == ""))
    |> length()
  end

  @spec extract_text_metadata(binary()) :: map()
  defp extract_text_metadata(content) do
    lines = String.split(content, "\n")

    %{
      line_count: length(lines),
      char_count: String.length(content)
    }
  end

  # Stage 4 & 5: Containerize (embedding happens inside SemanticContainer.create)
  @spec stage_containerize(binary(), String.t(), map(), keyword(), map()) ::
          {:ok, SemanticContainer.t()} | {:error, term()}
  defp stage_containerize(content, tenant_id, metadata, opts, state) do
    container_opts =
      opts
      |> Keyword.put(:metadata, metadata)
      |> Keyword.put(:content_type, metadata.content_type)

    SemanticContainer.create(state.container_server, content, tenant_id, container_opts)
  end

  # Helpers

  @spec generate_job_id() :: String.t()
  defp generate_job_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @spec count_jobs_by_status(map(), atom()) :: non_neg_integer()
  defp count_jobs_by_status(state, status) do
    Enum.count(state.jobs, fn {_id, job} -> job.status == status end)
  end

  @spec update_stats(map(), pipeline_result()) :: map()
  defp update_stats(state, %{status: :success, duration_ms: duration}) do
    new_stats =
      state.stats
      |> Map.update!(:total_ingested, &(&1 + 1))
      |> update_avg_duration(duration)

    %{state | stats: new_stats}
  end

  defp update_stats(state, %{status: :failed}) do
    new_stats = Map.update!(state.stats, :total_failed, &(&1 + 1))
    %{state | stats: new_stats}
  end

  defp update_stats(state, _), do: state

  @spec update_avg_duration(map(), non_neg_integer()) :: map()
  defp update_avg_duration(stats, new_duration) do
    total = stats.total_ingested
    old_avg = stats.avg_duration_ms

    new_avg =
      if total == 0 do
        new_duration
      else
        div(old_avg * total + new_duration, total + 1)
      end

    %{stats | avg_duration_ms: new_avg}
  end

  @spec emit_telemetry(atom(), integer(), map()) :: :ok
  defp emit_telemetry(event, start_time, metadata) do
    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      @telemetry ++ [event],
      %{duration: duration},
      metadata
    )
  end
end
