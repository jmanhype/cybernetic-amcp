#!/usr/bin/env elixir

# Standalone Telegram bot starter for Cybernetic
# Uses provided bot token to start the Telegram integration

defmodule TelegramBotStarter do
  def start(token) do
    IO.puts("\n🤖 STARTING CYBERNETIC TELEGRAM BOT")
    IO.puts("=" |> String.duplicate(50))
    IO.puts("Bot Token: #{String.slice(token, 0..20)}...")
    
    # Set the environment variable
    System.put_env("TELEGRAM_BOT_TOKEN", token)
    
    # Start minimal application components
    IO.puts("\n📡 Initializing Telegram Agent...")
    
    # Start the Telegram agent directly
    case Cybernetic.VSM.System1.Agents.TelegramAgent.start_link() do
      {:ok, pid} ->
        IO.puts("✅ Telegram Agent started: #{inspect(pid)}")
        IO.puts("\n🔗 Bot is now listening for messages!")
        IO.puts("Send a message to your bot to test:\n")
        IO.puts("  • 'hello' - Simple echo")
        IO.puts("  • 'think: <question>' - Complex reasoning via S4")
        IO.puts("  • 'policy: <query>' - Policy questions via S3")
        IO.puts("  • 'whoami' - Identity query via S5")
        IO.puts("\n⏳ Bot will run for 60 seconds...")
        
        # Keep the process alive
        Process.sleep(60_000)
        IO.puts("\n✅ Demo completed!")
        
      {:error, reason} ->
        IO.puts("❌ Failed to start Telegram Agent: #{inspect(reason)}")
    end
  end
end

# Get the token from user input or use the provided one
token = System.argv() |> List.first() || "7747520054:AAFNts5iJn8mYZezAG9uQF2_slvuztEScZI"

# Verify it looks like a valid token
if String.contains?(token, ":") do
  TelegramBotStarter.start(token)
else
  IO.puts("❌ Invalid token format. Expected format: 'BOT_ID:TOKEN'")
  IO.puts("Usage: elixir start_telegram_bot.exs YOUR_BOT_TOKEN")
end