# Technical Implementation Plan: VSM Platform Foundation

**Feature ID**: 001-vsm-platform-foundation
**Plan Version**: 1.0
**Created**: 2025-12-17
**Constitution Check**: ✅ Aligned with v1.0.0

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Docker Compose Stack                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   Phoenix    │  │   Phoenix    │  │   Phoenix    │              │
│  │  Edge GW 1   │  │  Edge GW 2   │  │  Edge GW N   │              │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘              │
│         │                  │                  │                      │
│         └──────────────────┼──────────────────┘                      │
│                            │                                         │
│                     ┌──────▼──────┐                                  │
│                     │   HAProxy   │  (Load Balancer)                 │
│                     └──────┬──────┘                                  │
│                            │                                         │
│  ┌─────────────────────────┼─────────────────────────┐              │
│  │                         │                          │              │
│  ▼                         ▼                          ▼              │
│ ┌──────────┐         ┌──────────┐              ┌──────────┐         │
│ │PostgreSQL│         │ RabbitMQ │              │  Redis   │         │
│ │  (Ecto)  │         │  (AMQP)  │              │ (Cache)  │         │
│ └──────────┘         └──────────┘              └──────────┘         │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────┐       │
│  │                    Oban Workers                           │       │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐     │       │
│  │  │Worker 1 │  │Worker 2 │  │Worker 3 │  │Worker N │     │       │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘     │       │
│  └──────────────────────────────────────────────────────────┘       │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────┐       │
│  │                   Storage Layer                           │       │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │       │
│  │  │ Local FS    │  │    MinIO    │  │   AWS S3    │      │       │
│  │  │  (dev)      │  │  (staging)  │  │   (prod)    │      │       │
│  │  └─────────────┘  └─────────────┘  └─────────────┘      │       │
│  └──────────────────────────────────────────────────────────┘       │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Technology Stack

| Layer | Technology | Version | Rationale |
|-------|------------|---------|-----------|
| **Language** | Elixir | 1.16+ | Already in use, excellent concurrency |
| **Framework** | Phoenix | 1.7+ | Already in use, LiveView for real-time |
| **Database** | PostgreSQL | 15+ | ACID, JSON support, pgvector ready |
| **ORM** | Ecto | 3.11+ | Native Elixir, migrations, changesets |
| **Background Jobs** | Oban | 2.17+ | PostgreSQL-backed, reliable, UI available |
| **Cache** | Redis | 7+ | Already configured via Redix |
| **Message Broker** | RabbitMQ | 3.12+ | Already configured via AMQP |
| **Containerization** | Docker | 24+ | Standard, compose for orchestration |
| **Storage** | Local/MinIO/S3 | - | Adapter pattern for flexibility |
| **Metrics** | Telemetry + PromEx | - | Native Elixir observability |

---

## 3. Component Design

### 3.1 Database Layer (PostgreSQL + Ecto)

**Directory Structure:**
```
lib/cybernetic/
├── repo.ex                     # Ecto Repo module
└── schemas/
    ├── vsm/
    │   ├── system_state.ex     # S1-S5 operational states
    │   ├── episode.ex          # S4 Intelligence episodes
    │   └── policy.ex           # S5 Policy decisions
    ├── storage/
    │   ├── artifact.ex         # Stored artifact metadata
    │   └── tenant.ex           # Multi-tenant isolation
    └── jobs/
        └── task_log.ex         # Background task history

priv/repo/migrations/
├── 20251217000001_create_tenants.exs
├── 20251217000002_create_system_states.exs
├── 20251217000003_create_episodes.exs
├── 20251217000004_create_policies.exs
├── 20251217000005_create_artifacts.exs
├── 20251217000006_create_oban_tables.exs
└── 20251217000007_enable_row_level_security.exs
```

**Key Decisions:**
- Use `binary_id` (UUID) for all primary keys (distributed-friendly)
- Enable Row-Level Security (RLS) for tenant isolation
- Use `jsonb` columns for flexible metadata
- Index foreign keys and commonly queried fields

### 3.2 Docker Compose Deployment

**File Structure:**
```
docker/
├── docker-compose.yml          # Main compose file
├── docker-compose.dev.yml      # Development overrides
├── docker-compose.prod.yml     # Production overrides
├── .env.example                # Environment template
├── postgres/
│   ├── init.sql                # Initial DB setup
│   └── postgresql.conf         # Postgres config
├── haproxy/
│   └── haproxy.cfg             # Load balancer config
└── scripts/
    ├── entrypoint.sh           # App entrypoint
    ├── healthcheck.sh          # Health check script
    └── wait-for-it.sh          # Dependency waiter
```

**Services:**
```yaml
services:
  app:
    build: .
    depends_on: [db, redis, rabbitmq]
    environment:
      - DATABASE_URL
      - REDIS_URL
      - RABBITMQ_URL
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
    deploy:
      replicas: 2
      resources:
        limits: { cpus: '1', memory: '1G' }

  db:
    image: postgres:15-alpine
    volumes: [pgdata:/var/lib/postgresql/data]
    environment:
      - POSTGRES_USER
      - POSTGRES_PASSWORD
      - POSTGRES_DB

  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes

  rabbitmq:
    image: rabbitmq:3.12-management-alpine

  oban_worker:
    build: .
    command: ["mix", "run", "--no-halt"]
    depends_on: [db]
    deploy:
      replicas: 2
```

### 3.3 Edge Gateway Controllers

**Directory Structure:**
```
lib/cybernetic/edge/gateway/controllers/
├── health_controller.ex        # /health, /ready, /live
├── metrics_controller.ex       # /metrics (Prometheus format)
├── events_controller.ex        # /v1/events (SSE streaming)
└── telegram_controller.ex      # /telegram/webhook
```

**SSE Implementation:**
```elixir
# events_controller.ex
defmodule Cybernetic.Edge.Gateway.EventsController do
  use Phoenix.Controller

  def stream(conn, params) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
    |> subscribe_and_stream(params["topics"])
  end

  defp subscribe_and_stream(conn, topics) do
    # Subscribe to Phoenix.PubSub topics
    # Stream events as SSE format
  end
end
```

### 3.4 Storage Abstraction Layer

**Directory Structure:**
```
lib/cybernetic/storage/
├── storage.ex                  # Main API module
├── adapter.ex                  # Behaviour definition
├── adapters/
│   ├── local.ex                # Local filesystem
│   ├── s3.ex                   # AWS S3 / MinIO
│   └── memory.ex               # In-memory (testing)
└── artifact.ex                 # Artifact struct
```

**Adapter Behaviour:**
```elixir
defmodule Cybernetic.Storage.Adapter do
  @callback store(path :: String.t(), content :: binary(), opts :: keyword()) ::
    {:ok, metadata :: map()} | {:error, reason :: term()}

  @callback retrieve(path :: String.t(), opts :: keyword()) ::
    {:ok, content :: binary()} | {:error, reason :: term()}

  @callback delete(path :: String.t(), opts :: keyword()) ::
    :ok | {:error, reason :: term()}

  @callback exists?(path :: String.t(), opts :: keyword()) :: boolean()

  @callback list(prefix :: String.t(), opts :: keyword()) ::
    {:ok, [String.t()]} | {:error, reason :: term()}
end
```

### 3.5 Background Processing (Oban)

**Directory Structure:**
```
lib/cybernetic/workers/
├── base_worker.ex              # Shared worker behaviour
├── episode_analyzer.ex         # S4 episode analysis
├── policy_evaluator.ex         # S5 policy evaluation
├── artifact_processor.ex       # Storage processing
└── notification_sender.ex      # External notifications
```

**Oban Configuration:**
```elixir
# config/config.exs
config :cybernetic, Oban,
  repo: Cybernetic.Repo,
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: [
      {"0 * * * *", Cybernetic.Workers.HealthCheck}
    ]}
  ],
  queues: [
    default: 10,
    critical: 20,
    analysis: 5,
    notifications: 5
  ]
```

---

## 4. Data Model

### 4.1 Core Schemas

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Tenant    │────<│ SystemState │     │   Episode   │
├─────────────┤     ├─────────────┤     ├─────────────┤
│ id (uuid)   │     │ id (uuid)   │     │ id (uuid)   │
│ name        │     │ tenant_id   │     │ tenant_id   │
│ slug        │     │ system (1-5)│     │ title       │
│ settings    │     │ state (json)│     │ content     │
│ created_at  │     │ version     │     │ analysis    │
│ updated_at  │     │ created_at  │     │ created_at  │
└─────────────┘     └─────────────┘     └─────────────┘
       │                                       │
       │            ┌─────────────┐            │
       └───────────>│   Policy    │<───────────┘
                    ├─────────────┤
                    │ id (uuid)   │
                    │ tenant_id   │
                    │ name        │
                    │ rules (json)│
                    │ active      │
                    │ created_at  │
                    └─────────────┘
                           │
                    ┌──────▼──────┐
                    │  Artifact   │
                    ├─────────────┤
                    │ id (uuid)   │
                    │ tenant_id   │
                    │ path        │
                    │ content_type│
                    │ size        │
                    │ metadata    │
                    │ created_at  │
                    └─────────────┘
```

### 4.2 Row-Level Security

```sql
-- Enable RLS on all tenant-scoped tables
ALTER TABLE system_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE episodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE artifacts ENABLE ROW LEVEL SECURITY;

-- Create policies
CREATE POLICY tenant_isolation ON system_states
  USING (tenant_id = current_setting('app.current_tenant')::uuid);
```

---

## 5. API Contracts

### 5.1 SSE Events Endpoint

```
GET /v1/events?topics=system.state,episode.created
Accept: text/event-stream

Response (streaming):
event: system.state
data: {"system": 4, "state": "analyzing", "timestamp": "..."}

event: episode.created
data: {"id": "...", "title": "...", "created_at": "..."}

: heartbeat
```

### 5.2 Metrics Endpoint

```
GET /metrics
Accept: text/plain

Response:
# HELP cybernetic_requests_total Total HTTP requests
# TYPE cybernetic_requests_total counter
cybernetic_requests_total{method="GET",path="/v1/generate"} 1234

# HELP cybernetic_request_duration_seconds Request latency
# TYPE cybernetic_request_duration_seconds histogram
cybernetic_request_duration_seconds_bucket{le="0.1"} 950
```

### 5.3 Telegram Webhook

```
POST /telegram/webhook
Content-Type: application/json
X-Telegram-Bot-Api-Secret-Token: <secret>

{
  "update_id": 123456,
  "message": {
    "chat": {"id": -100123},
    "text": "/status"
  }
}

Response: 200 OK
```

---

## 6. Testing Strategy

### 6.1 Test Pyramid

| Level | Coverage | Tools |
|-------|----------|-------|
| Unit | 90%+ | ExUnit, Mox |
| Integration | 80%+ | ExUnit, Ecto.Sandbox |
| E2E | Critical paths | Wallaby (if UI) |

### 6.2 Test Files

```
test/
├── cybernetic/
│   ├── repo_test.exs
│   ├── schemas/
│   │   ├── system_state_test.exs
│   │   └── episode_test.exs
│   ├── storage/
│   │   ├── storage_test.exs
│   │   └── adapters/
│   │       ├── local_test.exs
│   │       └── s3_test.exs
│   └── workers/
│       └── episode_analyzer_test.exs
├── cybernetic_edge/
│   └── gateway/
│       ├── health_controller_test.exs
│       ├── metrics_controller_test.exs
│       ├── events_controller_test.exs
│       └── telegram_controller_test.exs
└── support/
    ├── factory.ex
    └── fixtures/
```

---

## 7. Observability

### 7.1 Telemetry Events

```elixir
# Emit on every database query
:telemetry.execute(
  [:cybernetic, :repo, :query],
  %{duration: duration},
  %{query: query, source: source}
)

# Emit on every background job
:telemetry.execute(
  [:oban, :job, :complete],
  %{duration: duration},
  %{worker: worker, queue: queue}
)
```

### 7.2 PromEx Configuration

```elixir
config :cybernetic, Cybernetic.PromEx,
  plugins: [
    PromEx.Plugins.Application,
    PromEx.Plugins.Beam,
    {PromEx.Plugins.Phoenix, router: Cybernetic.Edge.Gateway.Router},
    PromEx.Plugins.Ecto,
    PromEx.Plugins.Oban
  ]
```

---

## 8. Performance Budgets

| Operation | p50 | p95 | p99 |
|-----------|-----|-----|-----|
| Health check | 5ms | 10ms | 20ms |
| Metrics scrape | 20ms | 50ms | 100ms |
| SSE connect | 50ms | 100ms | 200ms |
| DB query (simple) | 5ms | 20ms | 50ms |
| DB query (complex) | 20ms | 100ms | 200ms |
| Storage upload (1MB) | 100ms | 500ms | 1s |
| Background job enqueue | 5ms | 10ms | 20ms |

---

## 9. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Ecto migration failures | Test in staging, backup before, rollback plan |
| Oban job queue backup | Monitor queue depth, autoscale workers |
| SSE connection exhaustion | Connection limits, keepalive tuning |
| Storage adapter mismatch | Integration tests per adapter |
| Docker compose drift | Version lock, CI validation |

---

## 10. Rollout Plan

### Phase 1: Database Foundation (Week 1)
1. Create Ecto Repo and migrations
2. Implement core schemas
3. Enable RLS
4. Add seeds for development

### Phase 2: Docker Compose (Week 1)
1. Create compose files
2. Configure services
3. Add health checks
4. Test local deployment

### Phase 3: Controllers (Week 2)
1. Implement SSE streaming
2. Add Telegram webhook
3. Set up Prometheus metrics
4. Integration tests

### Phase 4: Storage & Workers (Week 2)
1. Implement storage adapters
2. Configure Oban
3. Create initial workers
4. End-to-end testing

---

## 11. Definition of Done

- [ ] All migrations run successfully
- [ ] Docker compose starts all services
- [ ] Health checks pass
- [ ] SSE streaming works end-to-end
- [ ] Telegram webhook receives and responds
- [ ] Metrics endpoint exports data
- [ ] Storage adapters pass integration tests
- [ ] Oban workers execute successfully
- [ ] Test coverage ≥ 90%
- [ ] Documentation updated
