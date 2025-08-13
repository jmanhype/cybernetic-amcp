# Apps Directory - Application Components

## Overview
Contains specialized application modules that extend the core Cybernetic framework.

## Applications

### Core
- CRDT implementation for distributed state
- MCP client for AI tool integration
- Security components (nonce, bloom filters)
- Transport behaviors and AMQP implementation
- Goldrush engine integration

### Telegram
- Bot agent for Telegram integration
- Command router for message handling
- Resilient client with retry logic
- Telemetry metrics collection

### VSM
- System 1-5 implementations
- Message handlers for each system
- Supervisors for fault tolerance

### Plugins
- Plugin behavior definition
- Dynamic plugin loading

### WASM
- WebAssembly runtime integration
- High-performance computing support

## Architecture Notes
- Each app is independently supervised
- Apps communicate via AMQP messages
- Shared state managed through CRDT
