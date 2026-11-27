import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :tenant_id, :trace_id]

# Ecto Repo configuration
config :cybernetic, Cybernetic.Repo,
  migration_primary_key: [name: :id, type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec],
  priv: "priv/repo"

config :cybernetic,
  ecto_repos: [Cybernetic.Repo]

# Oban Background Job Queue
config :cybernetic, Oban,
  engine: Oban.Engines.Basic,
  repo: Cybernetic.Repo,
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       # Health check every hour
       {"0 * * * *", Cybernetic.Workers.HealthCheck, queue: :default}
     ]}
  ],
  queues: [
    default: 10,
    critical: 20,
    analysis: 5,
    notifications: 5,
    storage: 3
  ]

# PromEx metrics configuration
config :cybernetic, Cybernetic.PromEx,
  disabled: false,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [],
  grafana: :disabled

config :libcluster,
  topologies: [
    cybernetic: [
      strategy: Cluster.Strategy.Gossip
    ]
  ]

# Transport configuration - Using AMQP as primary transport.
# Coupling #8: :transport is ALWAYS a bare module implementing
# Cybernetic.Transport.Behaviour - never a keyword list. The old
# keyword form (adapter/max_demand/nested amqp options) had no
# readers anywhere in lib/ and only "worked" because runtime.exs /
# test.exs overwrote it later in config load order. AMQP connection
# settings live under the top-level :amqp key (see runtime.exs);
# per-env transport overrides live in config/{env}.exs / runtime.exs.
config :cybernetic, :transport, Cybernetic.Transport.AMQP

# Phoenix Edge Gateway configuration
# P0 Security: secret_key_base moved to runtime.exs - DO NOT hardcode secrets
config :cybernetic, Cybernetic.Edge.Gateway.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: Cybernetic.Edge.Gateway.ErrorView, accepts: ~w(json)],
  live_view: [signing_salt: "GI8HdsmX-Wn5IyWB"]

# Craft Anything MCP bridge: registers the external Craft Anything
# MCP server's tools in the Hermes registry. Enabled on Jay's
# instruction (2026-11-27, MCP cleanup branch). The command is an
# absolute path because the boot process's PATH may not include
# ~/.local/bin; on hosts without the binary the bridge degrades to
# a logged absence (CraftClient stops with :command_not_found and
# the bridge stays up registering nothing) — no boot crash.
# The --deep flag runs Craft in Deep mode (reads inside study
# targets); the native toolset's tools are only listed in Deep mode.
config :cybernetic, :craft_mcp,
  enabled: true,
  command: "/home/hatch/.local/bin/craft-anything-cli",
  args: ["--deep", "mcp"],
  toolsets: ["native", "browser"]

# Embeddings: the single embedding source for capabilities discovery,
# content semantic search, and S4 memory (Axiomatic Design couplings
# #4/#5). Default provider is Ollama (local, no API key) with its
# nomic-embed-text model (768 dimensions). To use OpenAI instead:
#   config :cybernetic, :embeddings, provider: :openai, dimensions: 1536
# `dimensions` must match the provider model's output; it sizes the
# HNSW index started by the application.
config :cybernetic, :embeddings, provider: :ollama, dimensions: 768

# Import environment specific config
import_config "#{config_env()}.exs"
