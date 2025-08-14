import Config

# Load environment variables from .env file in test
if File.exists?(".env") do
  for line <- File.stream!(".env"),
      not String.starts_with?(line, "#"),
      String.contains?(line, "=") do
    
    line = String.trim(line)
    [key, value] = String.split(line, "=", parts: 2)
    System.put_env(String.trim(key), String.trim(value))
  end
end

# Configure to use InMemory transport during tests
config :cybernetic,
  transport: Cybernetic.Transport.InMemory,
  test_mode: true

# Disable AMQP during tests
config :cybernetic, :amqp,
  enabled: false
