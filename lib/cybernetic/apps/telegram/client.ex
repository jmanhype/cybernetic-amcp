defmodule Cybernetic.Apps.Telegram.Client do
  @moduledoc """
  Handler behind the MCP registry's `send_telegram` tool.

  The tool was registered against this module before it existed,
  so every invocation failed with an undefined-function error.
  This client is the adapter between the tool's parameter map
  and the real Telegram path,
  `Cybernetic.VSM.System1.Agents.TelegramAgent`: the message is
  handed to the agent through its own `send_message/3` API (a
  cast — the actual Telegram Bot API delivery is the agent's
  job).

  The result is honest about delivery:

  - agent not running → `{:error, :telegram_unavailable}`
  - agent running but no bot token configured → the message is
    still handed to the agent (which logs its no-token warning
    and drops the send), and the tool returns
    `{:error, :telegram_not_configured}` — a dispatch is never
    reported as a delivery
  - agent running and configured → `{:ok, %{status: :dispatched}}`
  """

  alias Cybernetic.VSM.System1.Agents.TelegramAgent

  @doc """
  Send a message via the Telegram agent.

  `params` carries `:chat_id` and `:text` (required) and
  `:options` (an optional map). Atom and string keys are
  accepted.
  """
  @spec send_message(map(), map()) ::
          {:ok, map()} | {:error, :telegram_unavailable | :telegram_not_configured | String.t()}
  def send_message(params, _context \\ %{}) when is_map(params) do
    with {:ok, chat_id} <- fetch_required(params, :chat_id),
         {:ok, text} <- fetch_required(params, :text),
         {:ok, options} <- fetch_options(params) do
      deliver(chat_id, text, options)
    end
  end

  defp deliver(chat_id, text, options) do
    case Process.whereis(TelegramAgent) do
      nil ->
        {:error, :telegram_unavailable}

      _pid ->
        TelegramAgent.send_message(chat_id, text, options)

        if bot_configured?() do
          {:ok, %{status: :dispatched, chat_id: chat_id}}
        else
          {:error, :telegram_not_configured}
        end
    end
  end

  # TelegramAgent reads the token from the environment at init
  # and drops sends without one; mirror that source of truth so
  # the tool never reports a bare dispatch as a delivery.
  defp bot_configured? do
    case System.get_env("TELEGRAM_BOT_TOKEN") do
      nil -> false
      "" -> false
      _token -> true
    end
  end

  defp fetch_required(params, key) do
    case params[key] || params[Atom.to_string(key)] do
      nil -> {:error, "missing required parameter: #{key}"}
      value -> {:ok, value}
    end
  end

  defp fetch_options(params) do
    case params[:options] || params["options"] do
      nil -> {:ok, %{}}
      options when is_map(options) -> {:ok, options}
      other -> {:error, "invalid options: expected a map, got #{inspect(other)}"}
    end
  end
end
