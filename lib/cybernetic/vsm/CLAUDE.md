# VSM Directory - Viable System Model Implementation

## Overview
Implementation of Stafford Beer's Viable System Model with 5 recursive systems.

## Systems

### System 1 - Operational
- **Purpose**: Handle day-to-day operations
- **Components**: 
  - `operational.ex` - Main supervisor
  - `message_handler.ex` - AMQP message routing
- **Responsibilities**: Entry points, worker processes, external interfaces

### System 2 - Coordination
- **Purpose**: Prevent oscillation between System 1 units
- **Components**:
  - `coordinator.ex` - Coordination logic
  - `message_handler.ex` - Inter-system messaging
- **Responsibilities**: Resource allocation, conflict resolution

### System 3 - Control
- **Purpose**: Operational management and optimization
- **Components**:
  - `control.ex` - Control logic
  - `message_handler.ex` - Control messaging
- **Responsibilities**: Performance monitoring, resource management

### System 4 - Intelligence  
- **Purpose**: Environmental scanning and adaptation
- **Components**:
  - `intelligence.ex` - Analysis engine
  - `message_handler.ex` - Intelligence routing
- **Responsibilities**: Learning, prediction, external monitoring

### System 5 - Policy
- **Purpose**: Identity and overall direction
- **Components**:
  - `policy.ex` - Policy engine
  - `message_handler.ex` - Policy messaging
- **Responsibilities**: Goal setting, identity maintenance

## Message Flow
1. External events → System 1
2. System 1 ↔ System 2 (coordination)
3. System 2 → System 3 (escalation)
4. System 3 ↔ System 4 (intelligence)
5. System 4 ↔ System 5 (policy)

## AMQP Queues
Canonical scheme: `sN.<channel>` keys on the `cyb.commands` exchange,
declared solely by `Cybernetic.Core.Transport.AMQP.Topology`.
- `cyb.s1.ops` (`s1.#`)
- `cyb.s2.coord` (`s2.#`)
- `cyb.s3.control` (`s3.#`)
- `cyb.s4.llm` (`s4.#`)
- `cyb.s5.policy` (`s5.#`)
EOF < /dev/null