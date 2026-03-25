# Cybernetic aMCP

Distributed AI coordination framework for Elixir, built around Stafford Beer's Viable System Model. Combines AMQP messaging, CRDTs, MCP tool integration, and multi-provider LLM routing into a single OTP application.

## Status

| Metric | Value |
|--------|-------|
| Version | 0.1.0 |
| Elixir | >= 1.18 |
| Runtime deps | 34 |
| Modules (.ex) | 218 |
| Test files | 96 |
| CI | GitHub Actions -- last run failed (Jan 2026, CI/CD Pipeline) |
| Database | PostgreSQL (required) |
| Message broker | RabbitMQ (required) |
| Test coverage threshold | 24% (configured in mix.exs) |

## What it does

Implements a 5-layer VSM architecture as OTP processes with AI agent coordination:

| Layer | Role | Key modules |
|-------|------|-------------|
| System 1 | Operations | Task execution, worker processes |
| System 2 | Coordination | Anti-oscillation, load balancing |
| System 3 | Control | Resource management, optimization |
| System 4 | Intelligence | LLM routing, environment scanning |
| System 5 | Policy | Governance, strategic direction |

Cross-cutting infrastructure:

- **AMQP transport** -- RabbitMQ with publisher pools, causality tracking, topology management
- **CRDT state** -- Distributed context graphs via delta_crdt
- **MCP integration** -- Hermes MCP client for tool protocol
- **LLM providers** -- Multi-provider routing via req_llm (Anthropic, OpenAI, Together, Ollama)
- **Edge gateway** -- Phoenix-based HTTP API with rate limiting, circuit breakers, OIDC
- **Security** -- Bloom filter replay protection, Argon2 hashing, JWT/JWKS verification
- **Content pipeline** -- Connectors for WordPress, Drupal, Ghost, Sanity, Strapi, Contentful, Google Drive
- **Observability** -- OpenTelemetry, Prometheus (prom_ex), LiveDashboard
- **Archeology tools** -- Static/dynamic analysis, system tracing, overlay tool

## Setup

Requires PostgreSQL, RabbitMQ, and Redis.

```bash
git clone https://github.com/jmanhype/cybernetic-amcp
cd cybernetic-amcp
cp .env.example .env   # Configure API keys
docker-compose -f config/docker/docker-compose.yml up -d
mix deps.get
mix ecto.create && mix ecto.migrate
iex -S mix
```

## Key dependencies

| Dependency | Purpose |
|-----------|---------|
| amqp ~> 4.1 | RabbitMQ client |
| delta_crdt | Distributed state |
| hermes_mcp (git, pinned SHA) | MCP tool protocol |
| req_llm ~> 1.0.0-rc.3 | LLM provider routing |
| phoenix ~> 1.7 | Edge gateway |
| ecto_sql ~> 3.11 | Database |
| oban ~> 2.17 | Background jobs |
| redix ~> 1.2 | Redis client |
| prom_ex ~> 1.9 | Prometheus metrics |
| opentelemetry ~> 1.4 | Distributed tracing |
| jose ~> 1.11 | JWT verification |
| argon2_elixir ~> 4.0 | Password hashing |

## Project structure

```
lib/cybernetic/
  core/
    crdt/           # Context graph, cache, graph queries
    goldrush/       # Reactive stream processing
    mcp/            # MCP server, handler, Hermes transport
    resilience/     # Circuit breakers, alerts
    security/       # Nonce bloom, rate limiter
    transport/      # AMQP connection, consumer, publisher
  edge/gateway/     # Phoenix endpoint, router, controllers, plugs
  system1-5/        # VSM layer implementations
  content/          # CMS connectors and semantic pipeline
  capabilities/     # LLM CDN, MCP router, planner
  archeology/       # System analysis and tracing tools
config/
  docker/           # Docker Compose for Postgres, RabbitMQ, Redis
infrastructure/     # Kubernetes manifests
```

## Limitations

- CI is not passing.
- Test coverage threshold is set to 24%, which is low. 96 test files exist but overall coverage is minimal.
- 218 modules at v0.1.0 indicates broad scope. Many subsystems (content connectors, archeology tools, Telegram bot) may be stubs or partially implemented.
- Requires 3 external services (PostgreSQL, RabbitMQ, Redis) plus LLM API keys to run.
- WASM policy evaluation is commented out in mix.exs due to rustler version conflicts.
- goldrush dependencies use git refs; one is pinned to a SHA, but `goldrush_elixir` uses a different SHA with `app: false`.
- No hex publication.
- The `.wreckit/` directory contains 30 tracked work items, most with status suggesting incomplete implementation.

## License

Not specified in mix.exs. Check repository for LICENSE file.
