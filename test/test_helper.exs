# Set test mode to prevent feedback loops
Application.put_env(:cybernetic, :test_mode, true)
Application.put_env(:cybernetic, :environment, :test)
Application.put_env(:cybernetic, :enable_telemetry, false)
Application.put_env(:cybernetic, :enable_health_monitoring, false)

# Use in-memory transport for tests
Application.put_env(:cybernetic, :transport, Cybernetic.Transport.InMemory)

# Ensure OpenTelemetry is fully disabled in unit tests
Application.put_env(:opentelemetry, :traces_exporter, :none)

# Start application services needed by unit tests
{:ok, _} = Application.ensure_all_started(:cybernetic)

# Integration tests run via `mix test --include integration`
ExUnit.start(exclude: [:integration])
