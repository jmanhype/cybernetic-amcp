
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
    url: {:system, "AMQP_URL", "amqp://guest:guest@localhost:5672"},
    prefetch_count: 10,
    consumers: [
      systems: [:system1, :system2, :system3, :system4, :system5],
      max_demand: 10,
      min_demand: 5
    ]
  ]
