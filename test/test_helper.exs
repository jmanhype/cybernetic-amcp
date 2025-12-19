# Set test mode to prevent feedback loops
Application.put_env(:cybernetic, :test_mode, true)

# Use in-memory transport for tests
Application.put_env(:cybernetic, :transport, Cybernetic.Transport.InMemory)

# Start application services needed by unit tests
{:ok, _} = Application.ensure_all_started(:cybernetic)

# Integration tests run via `mix test --include integration`
ExUnit.start(exclude: [:integration])
