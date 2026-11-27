defmodule Cybernetic.Core.Telemetry do
  @moduledoc """
  Handler behind the MCP registry's `telemetry_emit` tool.

  The tool was registered against this module before it existed,
  so every invocation failed with an undefined-function error.
  The implementation is a thin, validating bridge onto the real
  telemetry bus: the tool's dotted event string (for example
  `"cybernetic.mcp.emitted"`) is parsed into an event name and
  fired with `:telemetry.execute/3` using the caller's
  measurements and metadata.

  Malformed input — an empty or invalid event name, or non-map
  measurements/metadata — returns `{:error, message}` instead of
  raising inside the invocation task.
  """

  @segment_pattern ~r/^[a-zA-Z0-9_]+$/

  @doc """
  Emit a telemetry event.

  `params` carries `:event` (a dotted string, or a list of name
  segments), plus `:measurements` and `:metadata` (maps, both
  optional). Atom and string keys are accepted.
  """
  @spec emit(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def emit(params, _context \\ %{}) when is_map(params) do
    with {:ok, event} <- fetch_event(params),
         {:ok, measurements} <- fetch_map(params, :measurements),
         {:ok, metadata} <- fetch_map(params, :metadata) do
      :telemetry.execute(event, measurements, metadata)
      {:ok, %{event: event, emitted: true}}
    end
  end

  defp fetch_event(params) do
    case params[:event] || params["event"] do
      nil -> {:error, "missing required parameter: event"}
      event when is_binary(event) -> event |> String.split(".") |> validate_segments()
      event when is_list(event) -> validate_segments(event)
      other -> {:error, "invalid event name: #{inspect(other)}"}
    end
  end

  defp validate_segments(segments) do
    valid? =
      segments != [] and
        Enum.all?(segments, fn segment ->
          is_binary(segment) and segment =~ @segment_pattern
        end)

    if valid? do
      {:ok, Enum.map(segments, &String.to_atom/1)}
    else
      {:error, "invalid event name: #{inspect(segments)}"}
    end
  end

  defp fetch_map(params, key) do
    case params[key] || params[Atom.to_string(key)] do
      nil -> {:ok, %{}}
      value when is_map(value) -> {:ok, value}
      other -> {:error, "invalid #{key}: expected a map, got #{inspect(other)}"}
    end
  end
end
