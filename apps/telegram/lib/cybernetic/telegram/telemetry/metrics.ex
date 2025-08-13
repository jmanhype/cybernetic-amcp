defmodule Cybernetic.Telegram.Telemetry.Metrics do
  import Telemetry.Metrics
  def metrics do
    [
      counter("telegram.messages.in"),
      counter("telegram.messages.out"),
      last_value("telegram.latency.ms")
    ]
  end
end
