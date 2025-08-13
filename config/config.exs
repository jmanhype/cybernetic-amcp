
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

# Transport configuration
config :cybernetic, :transport,
  adapter: Cybernetic.Transport.GenStageAdapter,
  max_demand: 1000,
  consumers: [
    systems: [:system1, :system2, :system3, :system4, :system5],
    max_demand: 10,
    min_demand: 5
  ]
