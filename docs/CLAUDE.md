# Cybernetic aMCP Framework

## Overview
This is a distributed AI coordination framework implementing the Viable System Model (VSM) with AMQP messaging, CRDT state management, and MCP tool integration.

## Architecture
- **VSM Systems**: 5 hierarchical systems (S1-S5) for operational, coordination, control, intelligence, and policy management
- **Transport**: AMQP 4.1 for message passing between systems
- **State**: CRDT for distributed state synchronization
- **AI Tools**: MCP integration for AI agent capabilities

## Key Technologies
- Elixir 1.18.4
- OTP 28
- RabbitMQ 4.1.3
- AMQP 4.1.0
- DeltaCRDT for distributed state

## Important Files
- `mix.exs` - Project configuration and dependencies
- `lib/cybernetic/application.ex` - Main application supervisor
- `config/runtime.exs` - Runtime configuration for AMQP and VSM

## Testing
```bash
mix test
mix run test_amqp.exs  # Test AMQP connectivity
```

## Known Issues
- OTP 28 compatibility required patching `rabbit_cert_info.erl`
- GenStage transport removed in favor of AMQP

## Development Commands
```bash
iex -S mix  # Start interactive shell
mix compile # Compile the project
```