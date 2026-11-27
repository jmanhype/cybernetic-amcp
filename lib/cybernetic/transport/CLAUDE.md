# Transport Directory - Message Transport Layer

## Purpose
Handles all inter-system communication via AMQP.

## Key Components

### AMQP Connection
- `amqp/connection.ex` - Connection management with reconnection logic
- Maintains persistent connection to RabbitMQ
- Auto-reconnects on failure

## Configuration
- Connection URL from `AMQP_URL` env var
- Default: `amqp://guest:guest@localhost:5672`
- Exchange: `cyb.commands` (topic, durable)

## Queue Structure

Canonical addressing scheme: inter-system traffic uses `sN.<channel>`
routing keys on the `cyb.commands` exchange. All queues and bindings
are declared by a single site, `Cybernetic.Core.Transport.AMQP.Topology`.

```
cyb.commands (topic)
├── cyb.s1.ops      (s1.#)
├── cyb.s2.coord    (s2.#)
├── cyb.s3.control  (s3.#)
├── cyb.s4.llm      (s4.#)
└── cyb.s5.policy   (s5.#)
```

## Message Format
```elixir
%{
  "operation" => String.t(),
  "payload" => map(),
  "meta" => %{
    "timestamp" => DateTime.t(),
    "source" => String.t(),
    "correlation_id" => String.t()
  }
}
```

## Testing
```bash
mix run test_amqp.exs
```
