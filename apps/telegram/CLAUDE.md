# Telegram Application - Bot Integration

## Overview
Telegram bot application providing System 1 (Operations) interface for the Cybernetic framework. Enables human-in-the-loop interaction and operational command execution.

## Directory Structure
```
apps/telegram/
├── lib/
│   └── cybernetic/
│       └── telegram/
│           ├── bot/              # Bot core functionality
│           │   ├── agent.ex      # Main bot agent
│           │   └── supervisor.ex # Bot supervision tree
│           ├── client/           # Telegram API client
│           │   └── resilient.ex  # Fault-tolerant client
│           ├── commands/         # Command handlers
│           │   └── router.ex     # Command routing logic
│           └── telemetry/        # Metrics and monitoring
│               └── metrics.ex    # Telemetry metrics
└── test/                         # Bot tests
```

## Key Components

### Bot Agent
- **GenServer**: Stateful bot process
- **Message Handler**: Processes incoming Telegram messages
- **Command Dispatcher**: Routes commands to appropriate handlers
- **VSM Integration**: Connects to System 1 (Operations)

### Resilient Client
- **Retry Logic**: Exponential backoff for API failures
- **Circuit Breaker**: Prevents cascade failures
- **Connection Pooling**: Efficient API connection management
- **Rate Limiting**: Respects Telegram API limits

### Command Router
- **Command Registry**: Dynamic command registration
- **Middleware Pipeline**: Pre/post-processing hooks
- **Context Enrichment**: Adds metadata to commands
- **Response Formatting**: Structured message formatting

### Telemetry Metrics
- Messages in/out counters
- API latency tracking
- Error rate monitoring
- Command usage statistics

## Configuration
```elixir
# config/runtime.exs
config :cybernetic, :telegram,
  bot_token: System.get_env("TELEGRAM_BOT_TOKEN"),
  webhook_url: System.get_env("TELEGRAM_WEBHOOK_URL"),
  max_retries: 3,
  timeout: 5000
```

## Commands
- `/status` - System status overview
- `/metrics` - Performance metrics
- `/vsm` - VSM system states
- `/agents` - Active agent list
- `/help` - Command help

## Environment Variables
- `TELEGRAM_BOT_TOKEN` - Bot API token
- `TELEGRAM_WEBHOOK_URL` - Webhook endpoint (optional)
- `TELEGRAM_CHAT_ID` - Default chat ID (optional)

## Testing
```bash
mix test apps/telegram/test
```

## Important Notes
- Bot operates as System 1 interface
- All commands are logged and audited
- Supports both polling and webhook modes
- Implements graceful degradation on API failures