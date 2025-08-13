defmodule Cybernetic.Security.NonceBloom do
  @moduledoc """
  Replay prevention using Bloom filter (Rustler NIF placeholder).
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{seen: MapSet.new()}, name: __MODULE__)

  def seen?(nonce), do: GenServer.call(__MODULE__, {:seen?, nonce})
  def mark(nonce),  do: GenServer.cast(__MODULE__, {:mark, nonce})

  def init(s), do: {:ok, s}

  def handle_call({:seen?, nonce}, _f, s), do: {:reply, MapSet.member?(s.seen, nonce), s}
  def handle_cast({:mark, nonce}, s), do: {:noreply, %{s | seen: MapSet.put(s.seen, nonce)}}
end
