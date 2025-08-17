#!/usr/bin/env elixir

# Live Telegram Bot Runner
System.put_env("TELEGRAM_BOT_TOKEN", "7747520054:AAFNts5iJn8mYZezAG9uQF2_slvuztEScZI")

IO.puts("\n🤖 STARTING CYBERNETIC TELEGRAM BOT")
IO.puts("=" |> String.duplicate(60))
IO.puts("Bot: @VaoAssitantBot")
IO.puts("Token: #{String.slice(System.get_env("TELEGRAM_BOT_TOKEN"), 0..20)}...")

# Load and compile the project
Code.eval_file("mix.exs")
Mix.install(Mix.Project.config()[:deps], force: true, verbose: true)

# Start the application
IO.puts("\n📡 Starting application...")
{:ok, _} = Application.ensure_all_started(:logger)
{:ok, _} = Application.ensure_all_started(:telemetry)

# Start the Telegram Agent
IO.puts("🚀 Starting Telegram Agent...")

# Load the module
Code.eval_file("lib/cybernetic/vsm/system1/agents/telegram_agent.ex")

case Cybernetic.VSM.System1.Agents.TelegramAgent.start_link() do
  {:ok, pid} ->
    IO.puts("✅ Telegram bot started! PID: #{inspect(pid)}")
    IO.puts("\n📱 Bot is now LIVE and listening for messages!")
    IO.puts("Send a message to @VaoAssitantBot on Telegram")
    IO.puts("\nCommands:")
    IO.puts("  /start - Initialize conversation")
    IO.puts("  hello - Simple echo")
    IO.puts("  think: <question> - Complex reasoning")
    IO.puts("  whoami - Identity query")
    
    IO.puts("\n⏳ Bot will run for 5 minutes...")
    IO.puts("Press Ctrl+C to stop earlier")
    
    # Keep alive for 5 minutes
    Process.sleep(300_000)
    
  {:error, reason} ->
    IO.puts("❌ Failed to start bot: #{inspect(reason)}")
end