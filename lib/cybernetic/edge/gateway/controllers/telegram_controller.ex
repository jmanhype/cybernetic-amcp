defmodule Cybernetic.Edge.Gateway.TelegramController do
  @moduledoc """
  Webhook endpoint for Telegram bot updates.
  Receives incoming messages and forwards them to the TelegramAgent.
  """
  use Phoenix.Controller
  require Logger
  alias Cybernetic.VSM.System1.Agents.TelegramAgent

  @doc """
  Handle POST /telegram/webhook
  Processes incoming Telegram updates
  """
  def webhook(conn, params) do
    # Validate webhook signature if configured
    case validate_webhook(conn, params) do
      :ok ->
        process_update(conn, params)

      {:error, :invalid_signature} ->
        Logger.warning("Invalid Telegram webhook signature")

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid signature"})
    end
  end

  # Private Functions

  defp validate_webhook(conn, _params) do
    # Get webhook secret from environment
    secret_token = System.get_env("TELEGRAM_WEBHOOK_SECRET")

    if secret_token do
      # Validate X-Telegram-Bot-Api-Secret-Token header
      header_token = get_req_header(conn, "x-telegram-bot-api-secret-token") |> List.first()

      if header_token == secret_token do
        :ok
      else
        {:error, :invalid_signature}
      end
    else
      # No secret configured, allow all requests (not recommended for production)
      :ok
    end
  end

  defp process_update(conn, params) do
    # Extract message information
    case extract_message(params) do
      {:ok, message_data} ->
        # Forward to TelegramAgent
        TelegramAgent.handle_message(
          message_data.chat_id,
          message_data.text,
          message_data.from
        )

        # Emit telemetry
        :telemetry.execute(
          [:cybernetic, :edge, :telegram, :webhook_received],
          %{count: 1},
          %{chat_id: message_data.chat_id, update_id: params["update_id"]}
        )

        # Telegram expects 200 OK response
        conn
        |> put_status(:ok)
        |> json(%{ok: true})

      {:error, :no_message} ->
        # Update doesn't contain a message (could be edited message, callback query, etc.)
        # Just acknowledge it
        conn
        |> put_status(:ok)
        |> json(%{ok: true})

      {:error, reason} ->
        Logger.error("Failed to process Telegram update: #{inspect(reason)}")

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid update format"})
    end
  end

  defp extract_message(%{"message" => message}) do
    case message do
      %{"text" => text, "chat" => %{"id" => chat_id}, "from" => from} ->
        {:ok,
         %{
           chat_id: chat_id,
           text: text,
           from: from,
           message_id: message["message_id"]
         }}

      _ ->
        {:error, :invalid_message_format}
    end
  end

  defp extract_message(%{"edited_message" => _edited_message}) do
    # We could handle edited messages here if needed
    {:error, :no_message}
  end

  defp extract_message(%{"channel_post" => _channel_post}) do
    # We could handle channel posts here if needed
    {:error, :no_message}
  end

  defp extract_message(_params) do
    {:error, :no_message}
  end
end
