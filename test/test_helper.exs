# Set test mode to prevent feedback loops
Application.put_env(:cybernetic, :test_mode, true)

# Use in-memory transport for tests
Application.put_env(:cybernetic, :transport, Cybernetic.Transport.InMemory)

ExUnit.start()
