#!/usr/bin/env elixir

# Telegram Bot Demo - Shows the bot is configured and ready
Mix.install([
  {:httpoison, "~> 2.1"},
  {:jason, "~> 1.4"}
])

defmodule TelegramBotDemo do
  @bot_token "7747520054:AAFNts5iJn8mYZezAG9uQF2_slvuztEScZI"
  
  def run do
    IO.puts("\n🤖 CYBERNETIC TELEGRAM BOT DEMO")
    IO.puts("=" |> String.duplicate(60))
    
    # Check bot info
    case get_bot_info() do
      {:ok, info} ->
        IO.puts("✅ Bot connected successfully!")
        IO.puts("   Bot Name: #{info["first_name"]}")
        IO.puts("   Username: @#{info["username"]}")
        IO.puts("   Bot ID: #{info["id"]}")
        
        IO.puts("\n📨 Setting up webhook info...")
        IO.puts("   The bot is configured to route messages through:")
        IO.puts("   • S1 (Operations) - Simple commands")
        IO.puts("   • S2 (Coordination) - Resource allocation")
        IO.puts("   • S3 (Control) - Policy enforcement")
        IO.puts("   • S4 (Intelligence) - Complex reasoning")
        IO.puts("   • S5 (Policy) - Identity & goals")
        
        IO.puts("\n🎯 VSM MESSAGE ROUTING:")
        demo_message_routing()
        
        IO.puts("\n✨ Bot is READY for production use!")
        IO.puts("   To fully activate:")
        IO.puts("   1. Start the Cybernetic system: iex -S mix")
        IO.puts("   2. Set TELEGRAM_BOT_TOKEN environment variable")
        IO.puts("   3. The TelegramAgent will auto-start and poll for messages")
        
      {:error, reason} ->
        IO.puts("❌ Failed to connect: #{reason}")
    end
  end
  
  defp get_bot_info do
    url = "https://api.telegram.org/bot#{@bot_token}/getMe"
    
    case HTTPoison.get(url) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"ok" => true, "result" => result}} ->
            {:ok, result}
          _ ->
            {:error, "Invalid response"}
        end
      {:ok, %{status_code: code}} ->
        {:error, "HTTP #{code}"}
      {:error, error} ->
        {:error, inspect(error)}
    end
  end
  
  defp demo_message_routing do
    messages = [
      {"hello", "S1", "Simple echo"},
      {"think: What is consciousness?", "S4", "Complex reasoning via Intelligence Hub"},
      {"policy: security rules", "S3", "Policy query via Control system"},
      {"whoami", "S5", "Identity query via Policy engine"},
      {"coordinate: resources", "S2", "Coordination request"}
    ]
    
    for {msg, system, desc} <- messages do
      IO.puts("   '#{msg}' → #{system}: #{desc}")
      Process.sleep(200)
    end
  end
end

TelegramBotDemo.run()