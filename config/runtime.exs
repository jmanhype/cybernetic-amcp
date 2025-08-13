import Config

# Transport Configuration for VSM message passing
# Use AMQP transport in production, can be overridden in test.exs
config :cybernetic, :transport, Cybernetic.Transport.AMQP

# AMQP Configuration for production transport
config :cybernetic, :amqp,
  url: System.get_env("AMQP_URL") || "amqp://guest:guest@localhost:5672",
  exchange: System.get_env("AMQP_EXCHANGE") || "cyb.commands",
  exchange_type: :topic,
  exchanges: %{
    events: "cyb.events",
    telemetry: "cyb.telemetry", 
    commands: "cyb.commands",
    mcp_tools: "cyb.mcp.tools",
    s1: "cyb.vsm.s1",
    s2: "cyb.vsm.s2",
    s3: "cyb.vsm.s3",
    s4: "cyb.vsm.s4",
    s5: "cyb.vsm.s5"
  },
  queues: [
    system1: "vsm.system1.operations",
    system2: "vsm.system2.coordination", 
    system3: "vsm.system3.control",
    system4: "vsm.system4.intelligence",
    system5: "vsm.system5.policy"
  ]

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