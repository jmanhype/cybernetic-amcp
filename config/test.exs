import Config

# Configure to use InMemory transport during tests
config :cybernetic,
  transport: Cybernetic.Transport.InMemory,
  test_mode: true

# Disable AMQP during tests
config :cybernetic, :amqp,
  enabled: false
