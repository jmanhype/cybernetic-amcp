# Set test mode to prevent feedback loops
Application.put_env(:cybernetic, :test_mode, true)

# Use in-memory transport for tests
Application.put_env(:cybernetic, :transport, Cybernetic.Transport.InMemory)

# Start application to initialize AMQP topology and other services
{:ok, _} = Application.ensure_all_started(:cybernetic)

# Ensure AMQP topology is set up before tests run
# Retry until topology is successfully declared or timeout
defmodule TestHelper do
  def wait_for_topology(retries \\ 20) do
    case Cybernetic.Transport.AMQP.Connection.get_channel() do
      {:ok, channel} ->
        case Cybernetic.Core.Transport.AMQP.Topology.setup(channel) do
          :ok ->
            :ok

          {:error, _} when retries > 0 ->
            Process.sleep(200)
            wait_for_topology(retries - 1)

          error ->
            error
        end

      {:error, _} when retries > 0 ->
        Process.sleep(200)
        wait_for_topology(retries - 1)

      error ->
        error
    end
  end
end

case TestHelper.wait_for_topology() do
  :ok -> :ok
  error -> IO.puts("Warning: AMQP topology setup failed: #{inspect(error)}")
end

ExUnit.start()
