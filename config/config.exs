import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :libcluster,
  topologies: [
    cybernetic: [
      strategy: Cluster.Strategy.Gossip
    ]
  ]

# Transport configuration - Using AMQP as primary transport
config :cybernetic, :transport,
  adapter: Cybernetic.Transport.AMQP,
  max_demand: 1000,
  amqp: [
    url: "amqp://cybernetic:changeme@localhost:5672",
    prefetch_count: 10,
    consumers: [
      systems: [:system1, :system2, :system3, :system4, :system5],
      max_demand: 10,
      min_demand: 5
    ]
  ]

# Phoenix Edge Gateway configuration
config :cybernetic, Cybernetic.Edge.Gateway.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "YOUR_SECRET_KEY_BASE_HERE_64_CHARS_MIN_DEVELOPMENT_ONLY",
  render_errors: [view: Cybernetic.Edge.Gateway.ErrorView, accepts: ~w(json)]
