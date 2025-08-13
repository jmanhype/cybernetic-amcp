import Config

# GenStage/Broadway Configuration for distributed message passing
config :cybernetic, :transport,
  adapter: :gen_stage,
  producer_concurrency: 5,
  consumer_concurrency: 10,
  topics: [
    system1: "vsm.system1.operations",
    system2: "vsm.system2.coordination",
    system3: "vsm.system3.control",
    system4: "vsm.system4.intelligence",
    system5: "vsm.system5.policy"
  ],
  buffer_size: 1000,
  batch_size: 10

# VSM System Configuration
config :cybernetic, :vsm,
  enable_system1: true,
  enable_system2: true,
  enable_system3: true,
  enable_system4: true,
  enable_system5: true,
  telemetry_interval: 5_000

# MCP (Model Context Protocol) Configuration
config :cybernetic, :mcp,
  registry_timeout: 5_000,
  client_timeout: 30_000,
  max_retries: 3,
  enable_vsm_tools: true

# Goldrush Configuration for Event Processing
config :cybernetic, :goldrush,
  event_buffer_size: 1000,
  flush_interval: 100,
  enable_telemetry: true