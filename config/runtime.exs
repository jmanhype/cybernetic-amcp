import Config

# Transport Configuration for VSM message passing
# Use AMQP transport in production, can be overridden in test.exs
config :cybernetic, :transport, Cybernetic.Transport.AMQP

# AMQP Configuration for production transport
config :cybernetic, :amqp,
  url: System.get_env("AMQP_URL") || "amqp://cybernetic:changeme@localhost:5672",
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

# Security configuration
config :cybernetic, :security,
  hmac_secret:
    System.get_env("CYBERNETIC_HMAC_SECRET") || :crypto.strong_rand_bytes(32) |> Base.encode64(),
  # 5 minutes
  nonce_ttl: 300_000,
  bloom_size: 100_000,
  bloom_error_rate: 0.001

# NonceBloom specific config
config :cybernetic, Cybernetic.Core.Security.NonceBloom,
  replay_window_sec: 90,
  bloom_bits_per_entry: 10,
  bloom_error_rate: 0.001,
  persist_path: System.get_env("CYB_BLOOM_FILE") || "/tmp/cyb.bloom"

# S4 Intelligence Multi-Provider Configuration
config :cybernetic, :s4,
  default_chain: [
    anthropic: [model: "claude-3-5-sonnet-20241022"],
    openai: [model: "gpt-4o"],
    together: [model: "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo"],
    ollama: [model: "llama3.2:1b"]
  ],
  timeout_ms: 30_000,
  health_check_interval: 60_000,
  circuit_breaker_threshold: 5

# LLM Stack Selection (req_llm_pipeline or legacy_httpoison)
config :cybernetic, :llm_stack,
  stack: System.get_env("LLM_STACK", "legacy_httpoison") |> String.to_atom()

# Provider-specific configurations
config :cybernetic, Cybernetic.VSM.System4.Providers.Anthropic,
  api_key: {:system, "ANTHROPIC_API_KEY"},
  model: "claude-3-5-sonnet-20241022",
  max_tokens: 8192,
  temperature: 0.1

config :cybernetic, Cybernetic.VSM.System4.Providers.OpenAI,
  api_key: {:system, "OPENAI_API_KEY"},
  model: "gpt-4o",
  max_tokens: 4096,
  temperature: 0.1

config :cybernetic, Cybernetic.VSM.System4.Providers.Ollama,
  endpoint: System.get_env("OLLAMA_ENDPOINT") || "http://localhost:11434",
  model: "llama3.2:1b",
  max_tokens: 2048,
  temperature: 0.1

config :cybernetic, Cybernetic.VSM.System4.Providers.Together,
  api_key: {:system, "TOGETHER_API_KEY"},
  model: "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo",
  max_tokens: 4096,
  temperature: 0.1

# OpenTelemetry Configuration
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp,
  resource: [
    service: %{
      name: "cybernetic",
      version: "0.1.0"
    }
  ]

config :opentelemetry_exporter,
  otlp_protocol: :grpc,
  otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") || "http://localhost:4317",
  otlp_headers: System.get_env("OTEL_EXPORTER_OTLP_HEADERS") || "",
  otlp_compression: :gzip

# Prometheus metrics exporter
config :telemetry_metrics_prometheus_core,
  port: String.to_integer(System.get_env("METRICS_PORT") || "9568"),
  path: "/metrics",
  format: :text,
  registry: :default

# Application configuration
config :cybernetic,
  environment: config_env(),
  node_name: node()
