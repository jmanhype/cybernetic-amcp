# UI Application - Web Interface & Visualization

## Overview
Web-based user interface for monitoring, controlling, and visualizing the Cybernetic framework's distributed AI systems and VSM operations.

## Directory Structure
```
apps/ui/
├── lib/
│   └── cybernetic/
│       └── ui/
│           ├── web/           # Phoenix web framework
│           ├── live/          # LiveView components
│           ├── api/           # REST/GraphQL API
│           └── assets/        # Frontend assets
└── test/                      # UI tests
```

## Key Components

### Phoenix Web Framework
- **Endpoint**: HTTP/WebSocket server
- **Router**: Request routing and pipelines
- **Controllers**: Request handlers
- **Views**: Template rendering
- **Channels**: Real-time WebSocket communication

### LiveView Components
- **Dashboard**: Real-time system metrics
- **VSM Monitor**: Interactive VSM visualization
- **Agent Manager**: Agent lifecycle control
- **Message Flow**: Live message tracing
- **CRDT Visualizer**: Distributed state visualization

### API Endpoints
```
GET    /api/v1/status          # System status
GET    /api/v1/agents          # List agents
POST   /api/v1/agents          # Spawn agent
GET    /api/v1/vsm/:system     # VSM system state
POST   /api/v1/messages        # Send message
WS     /api/v1/stream          # Live event stream
```

### GraphQL Schema
```graphql
type Query {
  systemStatus: SystemStatus
  agents: [Agent]
  vsmState(system: Int!): VSMSystem
  messages(limit: Int): [Message]
}

type Mutation {
  spawnAgent(type: AgentType!): Agent
  sendMessage(target: String!, payload: JSON!): Message
  updatePolicy(policy: PolicyInput!): Policy
}

type Subscription {
  agentEvents: AgentEvent
  messageFlow: Message
  metricUpdates: Metric
}
```

## UI Features

### System Dashboard
- Real-time metrics (CPU, memory, messages/sec)
- Agent status grid
- VSM hierarchy visualization
- Alert notifications

### VSM Visualization
- Interactive system diagram
- Message flow animation
- Recursion level navigation
- Algedonic channel alerts

### Agent Control Panel
- Agent spawning interface
- Capability configuration
- Performance monitoring
- Log streaming

### Message Inspector
- Message tracing
- Queue depth monitoring
- Latency analysis
- Dead letter queue

### CRDT State Viewer
- Node synchronization status
- Conflict resolution history
- State diff visualization
- Merge operation log

## Frontend Stack
- **Phoenix LiveView**: Server-rendered reactive UI
- **Alpine.js**: Lightweight JavaScript framework
- **Tailwind CSS**: Utility-first CSS
- **Chart.js**: Data visualization
- **D3.js**: VSM system diagrams

## WebSocket Channels

### System Channel
```elixir
channel "system:*", Cybernetic.UI.SystemChannel
- "system:metrics" # Real-time metrics
- "system:alerts"  # System alerts
```

### Agent Channel
```elixir
channel "agent:*", Cybernetic.UI.AgentChannel
- "agent:status"   # Agent status updates
- "agent:logs"     # Agent log streaming
```

### VSM Channel
```elixir
channel "vsm:*", Cybernetic.UI.VSMChannel
- "vsm:s1" through "vsm:s5" # System-specific updates
```

## Configuration
```elixir
config :cybernetic, Cybernetic.UI.Endpoint,
  url: [host: "localhost"],
  http: [port: 4000],
  secret_key_base: "...",
  live_view: [signing_salt: "..."],
  pubsub_server: Cybernetic.PubSub
```

## Authentication & Authorization
- **Session-based Auth**: Cookie sessions
- **JWT Tokens**: API authentication
- **Role-based Access**: Admin, operator, viewer
- **Audit Logging**: All actions logged

## Testing
```bash
mix test apps/ui/test
mix test.watch  # Auto-run on file changes
```

## Development
```bash
cd apps/ui
mix phx.server  # Start Phoenix server
# Visit http://localhost:4000
```

## Important Notes
- LiveView provides real-time updates without JavaScript
- All UI updates are pushed from server via WebSockets
- Supports both REST and GraphQL APIs
- Dashboard auto-refreshes every second
- Mobile-responsive design using Tailwind CSS