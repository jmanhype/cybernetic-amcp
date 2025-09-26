import Config

# Load environment variables from .env file in development
if File.exists?(".env") do
  for line <- File.stream!(".env"),
      not String.starts_with?(line, "#"),
      String.contains?(line, "=") do
    line = String.trim(line)
    [key, value] = String.split(line, "=", parts: 2)
    System.put_env(String.trim(key), String.trim(value))
  end
end

# Development-specific configuration
config :cybernetic, :environment, :dev

# Enable debug logging
config :logger, :console,
  level: :debug,
  format: "$time $metadata[$level] $message\n"

# Phoenix Edge Gateway configuration
config :cybernetic, Cybernetic.Edge.Gateway.Endpoint,
  http: [port: 4000],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: []

# Configure Phoenix to use Jason for JSON
config :phoenix, :json_library, Jason

# TLS enforcement (disabled in dev)
config :cybernetic, :enforce_tls, false
