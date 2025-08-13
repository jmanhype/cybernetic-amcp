# Core Application - Foundation Components

## Overview
Core application providing essential building blocks for the Cybernetic framework including CRDT for distributed state, MCP client integration, security components, and the Goldrush engine.

## Directory Structure
```
apps/core/
├── lib/
│   └── cybernetic/
│       └── core/
│           ├── crdt/         # Conflict-free replicated data types
│           ├── mcp/          # Model Context Protocol integration
│           ├── security/     # Security components
│           └── goldrush/     # Goldrush engine integration
└── test/                     # Core component tests
```

## Key Components

### CRDT (Conflict-free Replicated Data Types)
- **Context Graph**: Distributed graph structure for agent coordination
- **Delta CRDT**: Efficient state synchronization across nodes
- **Merge strategies**: Automatic conflict resolution

### MCP (Model Context Protocol)
- **Client**: Connection to AI tool providers
- **Hermes Integration**: Enhanced MCP capabilities
- **Tool Registry**: Dynamic tool discovery and registration

### Security
- **Nonce Manager**: Cryptographic nonce generation
- **Bloom Filters**: Probabilistic data structures for efficient lookups
- **Capabilities**: Fine-grained permission system

### Goldrush Engine
- **Branch Management**: Git branch integration (develop-*, feature-*)
- **State Machine**: Workflow orchestration
- **Event Processing**: Reactive event handling

## Configuration
- MCP endpoints configured in runtime.exs
- CRDT replication factor: 3 (default)
- Bloom filter size: 10,000 elements
- Nonce expiry: 5 minutes

## Dependencies
- `delta_crdt` - CRDT implementation
- `rustler` - Native code integration
- `jason` - JSON encoding/decoding

## Testing
```bash
mix test apps/core/test
```

## Important Notes
- Core components are stateless where possible
- All state changes propagated via CRDT
- Security components use cryptographic primitives
- Goldrush integration requires Git configuration