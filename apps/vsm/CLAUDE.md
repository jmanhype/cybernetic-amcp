# VSM Application - Viable System Model Implementation

## Overview
Implementation of Stafford Beer's Viable System Model (VSM) with 5 hierarchical systems for organizational cybernetics and recursive management.

## Directory Structure
```
apps/vsm/
├── lib/
│   └── cybernetic/
│       └── vsm/
│           ├── system1/     # Operations
│           ├── system2/     # Coordination
│           ├── system3/     # Control
│           ├── system4/     # Intelligence
│           ├── system5/     # Policy
│           └── messages/    # Message handlers
└── test/                    # VSM tests
```

## VSM Systems

### System 1 - Operations
- **Purpose**: Execute primary activities
- **Components**: 
  - Operational units performing core functions
  - Direct value creation processes
  - Resource management
- **AMQP Queue**: `cybernetic.vsm.s1.operations`
- **Telegram Integration**: Human interface for operational commands

### System 2 - Coordination
- **Purpose**: Prevent oscillation between operational units
- **Components**:
  - Anti-oscillation mechanisms
  - Coordination protocols
  - Conflict resolution
- **AMQP Queue**: `cybernetic.vsm.s2.coordination`
- **Message Types**: Coordination requests, sync signals

### System 3 - Control
- **Purpose**: Manage and optimize operations
- **Components**:
  - Resource allocation
  - Performance monitoring
  - Operational optimization
- **AMQP Queue**: `cybernetic.vsm.s3.control`
- **Audit Channel**: System 3* for direct monitoring

### System 4 - Intelligence
- **Purpose**: Look outward and forward
- **Components**:
  - Environmental scanning
  - Future planning
  - Strategic adaptation
- **AMQP Queue**: `cybernetic.vsm.s4.intelligence`
- **External Integration**: MCP tools, external APIs

### System 5 - Policy
- **Purpose**: Define identity and purpose
- **Components**:
  - Policy formulation
  - Identity maintenance
  - Ultimate authority
- **AMQP Queue**: `cybernetic.vsm.s5.policy`
- **Governance**: System-wide policies and constraints

## Message Flow
```
S5 (Policy)
    ↓
S4 (Intelligence) ←→ S3 (Control)
                      ↓
                 S2 (Coordination)
                      ↓
                 S1 (Operations)
```

## Recursion
Each System 1 operational unit can itself be a complete VSM, creating recursive hierarchies:
- Organization → Divisions → Departments → Teams
- Each level maintains its own S1-S5 structure

## Configuration
```elixir
config :cybernetic, :vsm,
  recursion_depth: 3,
  audit_enabled: true,
  algedonic_channel: true
```

## Algedonic Channel
Direct alert pathway from any level to System 5 for critical issues:
- Bypasses normal hierarchy
- Triggers immediate policy attention
- Used for existential threats

## Testing
```bash
mix test apps/vsm/test
```

## Important Notes
- VSM provides organizational viability
- Each system has specific variety management requirements
- Recursion enables fractal organization structures
- Maintains Ashby's Law of Requisite Variety