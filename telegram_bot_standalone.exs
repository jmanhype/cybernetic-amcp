#!/usr/bin/env elixir

# Standalone Telegram Bot - Runs independently
Mix.install([
  {:httpoison, "~> 2.1"},
  {:jason, "~> 1.4"}
])

defmodule CyberneticBot do
  @bot_token "7747520054:AAFNts5iJn8mYZezAG9uQF2_slvuztEScZI"
  @bot_name "@VaoAssitantBot"
  
  def start do
    IO.puts("\n🤖 CYBERNETIC TELEGRAM BOT RUNNING")
    IO.puts("=" |> String.duplicate(60))
    IO.puts("Bot: #{@bot_name}")
    IO.puts("Status: ACTIVE ✅")
    IO.puts("\n📱 The bot is now LIVE on Telegram!")
    IO.puts("Send a message to #{@bot_name} and it will respond")
    
    # Start polling loop
    IO.puts("\n🔄 Starting message polling...")
    poll_loop(0)
  end
  
  def poll_loop(offset) do
    url = "https://api.telegram.org/bot#{@bot_token}/getUpdates?offset=#{offset}&timeout=5"
    
    case HTTPoison.get(url, [], recv_timeout: 10_000) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"ok" => true, "result" => updates}} when updates != [] ->
            # Process each update
            new_offset = process_updates(updates, offset)
            poll_loop(new_offset)
            
          _ ->
            # No new messages
            IO.write(".")
            poll_loop(offset)
        end
        
      error ->
        IO.puts("\n⚠️ Connection error: #{inspect(error)}")
        Process.sleep(5000)
        poll_loop(offset)
    end
  end
  
  defp process_updates([], offset), do: offset
  defp process_updates([update | rest], offset) do
    update_id = update["update_id"]
    
    if message = update["message"] do
      chat_id = message["chat"]["id"]
      text = message["text"] || ""
      from = message["from"]["first_name"] || "User"
      
      IO.puts("\n📨 Message from #{from}: #{text}")
      
      # Route and respond
      response = route_message(text)
      send_response(chat_id, response)
    end
    
    process_updates(rest, update_id + 1)
  end
  
  defp route_message(text) do
    cond do
      String.starts_with?(text, "/start") ->
        "🚀 Welcome to Cybernetic VSM Bot!\n\nI route messages through 5 VSM systems:\n• S1: Operations\n• S2: Coordination\n• S3: Control\n• S4: Intelligence\n• S5: Policy\n\nTry: 'hello', 'think: <question>', 'whoami'"
        
      String.starts_with?(text, "think:") || String.contains?(text, "?") ->
        "🧠 [S4 Intelligence] Processing complex query: #{text}\n\nAnalysis: This would be routed through the S4 Intelligence Hub for reasoning."
        
      text in ["whoami", "who are you", "identity"] ->
        "🎯 [S5 Policy] I am the Cybernetic VSM Bot, implementing Stafford Beer's Viable System Model for distributed AI coordination."
        
      String.starts_with?(text, "policy:") ->
        "📋 [S3 Control] Policy query received. S3 would enforce relevant rules and constraints."
        
      String.starts_with?(text, "coordinate:") ->
        "🔄 [S2 Coordination] Resource allocation request. S2 would manage inter-system coordination."
        
      true ->
        "✅ [S1 Operations] Echo: #{text}\n\nSimple operational response from System 1."
    end
  end
  
  defp send_response(chat_id, text) do
    url = "https://api.telegram.org/bot#{@bot_token}/sendMessage"
    body = Jason.encode!(%{
      chat_id: chat_id,
      text: text,
      parse_mode: "Markdown"
    })
    
    case HTTPoison.post(url, body, [{"Content-Type", "application/json"}]) do
      {:ok, %{status_code: 200}} ->
        IO.puts("✅ Response sent")
      error ->
        IO.puts("❌ Failed to send: #{inspect(error)}")
    end
  end
end

# Start the bot
IO.puts("\n🚀 Launching Cybernetic Telegram Bot...")
IO.puts("Press Ctrl+C twice to stop\n")

CyberneticBot.start()