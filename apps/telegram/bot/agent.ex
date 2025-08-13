
defmodule Cybernetic.Telegram.Agent do
  @moduledoc """
  S1 entrypoint: receives chat events, writes CRDT context, escalates to S4 when needed.
  """
  use GenServer
  require Logger

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    Process.send_after(self(), :poll, 0)
    {:ok, %{offset: 0}}
  end

  def handle_info(:poll, state) do
    # Minimal polling loop (replace with webhook/long-poll as desired)
    case poll_updates(state.offset) do
      {:ok, updates, next_offset} ->
        Enum.each(updates, &handle_update/1)
        Process.send_after(self(), :poll, 1000)
        {:noreply, %{state | offset: next_offset}}
      {:error, _} ->
        Process.send_after(self(), :poll, 3000)
        {:noreply, state}
    end
  end

  defp poll_updates(offset) do
    # Nadia.get_updates/1 returns {:ok, [%{update_id: ..., message: ...}], _}
    try do
      case Nadia.get_updates(offset: offset, timeout: 1) do
        {:ok, updates} ->
          next = Enum.reduce(updates, offset, fn u, acc -> max(acc, u.update_id + 1) end)
          {:ok, updates, next}
        other -> other
      end
    rescue
      _ -> {:error, :unavailable}
    end
  end

  defp handle_update(%{message: %{message_id: mid, text: text, chat: %{id: chat_id}}} = msg) when is_binary(text) do
    # Persist to CRDT semantic context
    Cybernetic.Core.CRDT.ContextGraph.add("telegram:#{chat_id}", "said", text, %{mid: mid})

    # Route to S2/S3/S4 based on heuristic (simple: LLM when text starts with '/ask ')
    if String.starts_with?(text, "/ask ") do
      prompt = String.replace_prefix(text, "/ask ", "")
      case Cybernetic.System4.LLMBridge.ask(%{prompt: prompt, channel: "telegram", chat_id: chat_id}) do
        {:ok, answer} -> Nadia.send_message(chat_id, answer)
        {:error, _} -> :ok
      end
    end
  end
  defp handle_update(_), do: :ok
end
