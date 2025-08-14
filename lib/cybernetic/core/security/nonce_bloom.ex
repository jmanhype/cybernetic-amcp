defmodule Cybernetic.Core.Security.NonceBloom do
  @moduledoc """
  Nonce generation and bloom filter replay protection for AMQP messages.
  Prevents replay attacks by tracking seen nonces in a probabilistic data structure.
  """
  
  use GenServer
  require Logger
  
  @bloom_size 100_000
  @bloom_error_rate 0.001
  @nonce_ttl 300_000  # 5 minutes in milliseconds
  @cleanup_interval 60_000  # 1 minute
  @telemetry_ns [:cybernetic, :security, :nonce_bloom]
  
  defstruct [:bloom, :seen_nonces, :last_cleanup]
  
  # Client API
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @doc """
  Generate a new cryptographic nonce
  """
  def generate_nonce do
    Nanoid.generate(21)  # 21 chars = 126 bits of entropy
  end
  
  @doc """
  Check if a nonce has been seen before (replay detection)
  Returns {:ok, :new} if nonce is new, {:error, :replay} if seen before
  """
  def check_nonce(nonce) do
    GenServer.call(__MODULE__, {:check_nonce, nonce})
  end
  
  @doc """
  Get the TTL for nonces in milliseconds
  """
  def ttl_ms, do: @nonce_ttl
  
  @doc """
  Manually trigger cleanup of expired nonces
  """
  def prune do
    GenServer.cast(__MODULE__, :prune)
  end
  
  @doc """
  Enrich a message with security headers (nonce, timestamp, signature)
  """
  def enrich_message(payload, opts \\ []) do
    nonce = generate_nonce()
    timestamp = System.system_time(:millisecond)
    site = opts[:site] || node()
    {signature, key_id} = generate_signature(payload, nonce, timestamp)
    
    enriched = Map.merge(payload, %{
      "_nonce" => nonce,
      "_timestamp" => timestamp,
      "_site" => site,
      "_signature" => signature,
      "_key_id" => key_id
    })
    
    # Track the nonce we just generated
    GenServer.cast(__MODULE__, {:track_nonce, nonce, timestamp})
    
    enriched
  end
  
  @doc """
  Validate an incoming message's security headers
  """
  def validate_message(message) do
    with {:ok, :has_headers} <- check_headers(message),
         {:ok, :valid_timestamp} <- validate_timestamp(message["_timestamp"]),
         {:ok, :new} <- check_nonce(message["_nonce"]),
         {:ok, :valid_signature} <- validate_signature(message) do
      {:ok, strip_security_headers(message)}
    else
      {:error, reason} ->
        Logger.warning("Message validation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  # Server callbacks
  
  @impl true
  def init(_opts) do
    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval)
    
    state = %__MODULE__{
      bloom: Bloomex.plain(@bloom_size, @bloom_error_rate),
      seen_nonces: %{},
      last_cleanup: System.system_time(:millisecond)
    }
    
    {:ok, state}
  end
  
  @impl true
  def handle_call({:check_nonce, nonce}, _from, state) do
    if Bloomex.member?(state.bloom, nonce) or Map.has_key?(state.seen_nonces, nonce) do
      {:reply, {:error, :replay}, state}
    else
      # Add to bloom filter and track with timestamp
      new_bloom = Bloomex.add(state.bloom, nonce)
      new_seen = Map.put(state.seen_nonces, nonce, System.system_time(:millisecond))
      
      new_state = %{state | bloom: new_bloom, seen_nonces: new_seen}
      {:reply, {:ok, :new}, new_state}
    end
  end
  
  @impl true
  def handle_cast({:track_nonce, nonce, timestamp}, state) do
    new_bloom = Bloomex.add(state.bloom, nonce)
    new_seen = Map.put(state.seen_nonces, nonce, timestamp)
    
    {:noreply, %{state | bloom: new_bloom, seen_nonces: new_seen}}
  end
  
  @impl true
  def handle_cast(:prune, state) do
    # Trigger immediate cleanup
    send(self(), :cleanup)
    {:noreply, state}
  end
  
  @impl true
  def handle_info(:cleanup, state) do
    # Remove expired nonces from tracking
    now = System.system_time(:millisecond)
    cutoff = now - @nonce_ttl
    
    old_count = map_size(state.seen_nonces)
    new_seen = state.seen_nonces
    |> Enum.filter(fn {_nonce, timestamp} -> timestamp > cutoff end)
    |> Enum.into(%{})
    
    new_count = map_size(new_seen)
    dropped_count = old_count - new_count
    
    # Emit telemetry metrics
    :telemetry.execute(
      @telemetry_ns ++ [:cleanup],
      %{dropped: dropped_count, kept: new_count, total_before: old_count},
      %{}
    )
    
    # Rebuild bloom filter if we removed many entries
    new_bloom = if new_count < old_count * 0.7 do
      # Rebuild bloom with only active nonces
      Enum.reduce(Map.keys(new_seen), Bloomex.plain(@bloom_size, @bloom_error_rate), fn nonce, bloom ->
        Bloomex.add(bloom, nonce)
      end)
    else
      state.bloom
    end
    
    Logger.debug("Nonce cleanup: removed #{dropped_count} expired nonces")
    
    # Schedule next cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval)
    
    {:noreply, %{state | bloom: new_bloom, seen_nonces: new_seen, last_cleanup: now}}
  end
  
  # Private functions
  
  defp check_headers(message) do
    required = ["_nonce", "_timestamp", "_site", "_signature"]
    if Enum.all?(required, &Map.has_key?(message, &1)) do
      {:ok, :has_headers}
    else
      {:error, :missing_security_headers}
    end
  end
  
  defp validate_timestamp(timestamp) when is_integer(timestamp) do
    now = System.system_time(:millisecond)
    skew = now - timestamp
    max_skew = Application.get_env(:cybernetic, :max_clock_skew_ms, 90_000)  # 90 seconds default
    
    # Emit telemetry for clock skew monitoring
    :telemetry.execute(
      @telemetry_ns ++ [:clock_skew],
      %{skew_ms: abs(skew)},
      %{direction: if(skew < 0, do: :future, else: :past)}
    )
    
    cond do
      abs(skew) > max_skew and skew < 0 -> {:error, :clock_skew_future}
      abs(skew) > max_skew and skew > 0 -> {:error, :clock_skew_past}
      skew > @nonce_ttl -> {:error, :expired_timestamp}
      true -> {:ok, :valid_timestamp}
    end
  end
  defp validate_timestamp(_), do: {:error, :invalid_timestamp}
  
  defp validate_signature(message) do
    payload = strip_security_headers(message)
    expected = generate_signature(payload, message["_nonce"], message["_timestamp"])
    
    if expected == message["_signature"] do
      {:ok, :valid_signature}
    else
      {:error, :invalid_signature}
    end
  end
  
  @doc """
  Generate canonical string for signing - deterministic order
  Includes routing metadata to prevent cross-topic replay
  """
  def canonical_string(payload, nonce, timestamp, site \\ nil, meta \\ %{}) do
    # Deterministic order for signing - includes routing keys
    [
      nonce,
      timestamp,
      site || node(),
      Map.get(meta, :exchange, ""),
      Map.get(meta, :routing_key, ""),
      Map.get(meta, :content_type, "application/json"),
      Jason.encode!(payload)
    ]
    |> Enum.join("|")
  end
  
  defp generate_signature(payload, nonce, timestamp) do
    # Proper HMAC signature using a secret key
    {key_id, secret} = get_current_key()
    data = canonical_string(payload, nonce, timestamp)
    sig = :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)
    {sig, key_id}
  end

  defp get_current_key do
    # Support key rotation with key IDs
    case Application.get_env(:cybernetic, :security)[:signing_keys] do
      %{active: %{id: id, secret: secret}} -> 
        {id, secret}
      _ ->
        # Fallback to single key
        secret = get_hmac_secret()
        {"default", secret}
    end
  end

  defp get_hmac_secret do
    # In production, rotate this secret regularly and store securely
    Application.get_env(:cybernetic, :security)[:hmac_secret] ||
    System.get_env("CYBERNETIC_HMAC_SECRET") ||
    "default-insecure-key-change-in-production"
  end
  
  defp strip_security_headers(message) do
    Map.drop(message, ["_nonce", "_timestamp", "_site", "_signature"])
  end
end