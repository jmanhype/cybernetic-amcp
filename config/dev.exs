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
