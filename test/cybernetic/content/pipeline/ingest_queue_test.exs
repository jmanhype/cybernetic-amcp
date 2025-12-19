defmodule Cybernetic.Content.Pipeline.IngestQueueTest do
  use ExUnit.Case, async: false

  alias Cybernetic.Content.Pipeline.Ingest

  defmodule StubContainerServer do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(_opts) do
      {:ok, %{counter: 0}}
    end

    @impl true
    def handle_call({:create, _content, tenant_id, _opts}, _from, state) do
      id = "container-#{state.counter + 1}"
      {:reply, {:ok, %{id: id, tenant_id: tenant_id}}, %{state | counter: state.counter + 1}}
    end
  end

  setup do
    {:ok, container_server} = start_supervised(StubContainerServer)

    server = __MODULE__.IngestServer

    pid =
      start_supervised!(
        {Ingest, name: server, container_server: container_server, max_concurrent: 1}
      )

    {:ok, server: server, pid: pid}
  end

  test "queue_ingest stores result with same job id", %{server: server} do
    {:ok, job_id} =
      Ingest.queue_ingest(server, %{content: "hello", content_type: "text/plain"}, "tenant-1")

    job = await_job(server, job_id)

    assert job.id == job_id
    assert job.status == :completed
    assert job.result.id == job_id
    assert job.result.status == :success
    assert is_integer(job.result.bytes_ingested) and job.result.bytes_ingested > 0

    stats = Ingest.stats(server)
    assert stats.total_ingested == 1
    assert stats.total_bytes == job.result.bytes_ingested
    assert stats.avg_duration_ms == job.result.duration_ms
  end

  defp await_job(server, job_id) do
    Enum.reduce_while(1..50, nil, fn _, _ ->
      case Ingest.get_job(server, job_id) do
        {:ok, %{status: status} = job} when status in [:completed, :failed] ->
          {:halt, job}

        {:ok, _job} ->
          Process.sleep(10)
          {:cont, nil}

        {:error, :not_found} ->
          Process.sleep(10)
          {:cont, nil}
      end
    end) ||
      flunk("job did not complete in time: #{job_id}")
  end
end
