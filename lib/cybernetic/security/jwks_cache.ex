defmodule Cybernetic.Security.JWKSCache do
  @moduledoc """
  GenServer-owned cache for JWKS keys and OIDC discovery.

  Security: ETS table is :protected (only this GenServer can write).
  Callers read via GenServer.call to ensure consistent cache state.

  Features:
  - TTL-based cache expiration (default 5 minutes)
  - Strict timeouts on HTTP fetches (prevents slow loris)
  - HTTPS enforcement in production for JWKS URLs
  """

  use GenServer
  require Logger

  @cache_table :cybernetic_jwks_cache
  @default_ttl_ms :timer.minutes(5)
  @http_timeout_ms 10_000
  @http_connect_timeout_ms 5_000
  @max_redirects 2

  # Public API

  @doc "Start the JWKS cache GenServer"
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get JWKS keys for a URL (cached)"
  @spec get_keys(String.t()) :: {:ok, map()} | {:error, term()}
  def get_keys(jwks_url) when is_binary(jwks_url) do
    GenServer.call(__MODULE__, {:get_keys, jwks_url}, @http_timeout_ms + 5_000)
  end

  @doc "Discover JWKS URL from OIDC issuer (cached)"
  @spec discover_jwks_url(String.t()) :: {:ok, String.t()} | {:error, term()}
  def discover_jwks_url(issuer) when is_binary(issuer) do
    GenServer.call(__MODULE__, {:discover_jwks_url, issuer}, @http_timeout_ms + 5_000)
  end

  @doc "Clear all cached entries"
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc "Get cache statistics"
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Create ETS with :protected access - only this GenServer can write
    :ets.new(@cache_table, [
      :named_table,
      :set,
      :protected,
      {:read_concurrency, true}
    ])

    state = %{
      hits: 0,
      misses: 0,
      fetch_errors: 0
    }

    Logger.info("JWKSCache started with #{@default_ttl_ms}ms TTL")
    {:ok, state}
  end

  @impl true
  def handle_call({:get_keys, jwks_url}, _from, state) do
    now_ms = System.system_time(:millisecond)
    ttl_ms = cache_ttl_ms()

    case :ets.lookup(@cache_table, {:jwks, jwks_url}) do
      [{_, keys, fetched_at}] when now_ms - fetched_at < ttl_ms ->
        {:reply, {:ok, keys}, %{state | hits: state.hits + 1}}

      _ ->
        # Cache miss - fetch JWKS
        case fetch_jwks(jwks_url) do
          {:ok, keys} ->
            :ets.insert(@cache_table, {{:jwks, jwks_url}, keys, now_ms})
            {:reply, {:ok, keys}, %{state | misses: state.misses + 1}}

          {:error, reason} = error ->
            Logger.warning("JWKS fetch failed for #{jwks_url}: #{inspect(reason)}")
            {:reply, error, %{state | fetch_errors: state.fetch_errors + 1}}
        end
    end
  end

  @impl true
  def handle_call({:discover_jwks_url, issuer}, _from, state) do
    now_ms = System.system_time(:millisecond)
    ttl_ms = cache_ttl_ms()

    case :ets.lookup(@cache_table, {:discovery, issuer}) do
      [{_, jwks_url, fetched_at}] when now_ms - fetched_at < ttl_ms ->
        {:reply, {:ok, jwks_url}, %{state | hits: state.hits + 1}}

      _ ->
        # Cache miss - discover JWKS URL
        case discover_from_issuer(issuer) do
          {:ok, jwks_url} ->
            :ets.insert(@cache_table, {{:discovery, issuer}, jwks_url, now_ms})
            {:reply, {:ok, jwks_url}, %{state | misses: state.misses + 1}}

          {:error, reason} = error ->
            Logger.warning("OIDC discovery failed for #{issuer}: #{inspect(reason)}")
            {:reply, error, %{state | fetch_errors: state.fetch_errors + 1}}
        end
    end
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@cache_table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    cache_size = :ets.info(@cache_table, :size)
    {:reply, Map.put(state, :cache_size, cache_size), state}
  end

  # Private helpers

  defp fetch_jwks(url) do
    with :ok <- validate_url(url),
         {:ok, %{status: 200, body: body}} <- safe_get(url),
         {:ok, json} <- decode_json(body),
         %{"keys" => keys} when is_list(keys) <- json do
      {:ok, build_keys_map(keys)}
    else
      %{} = json when not is_map_key(json, "keys") ->
        {:error, {:invalid_jwks, :missing_keys}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, truncate_body(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discover_from_issuer(issuer) do
    discovery_url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    with :ok <- validate_url(discovery_url),
         {:ok, %{status: 200, body: body}} <- safe_get(discovery_url),
         {:ok, json} <- decode_json(body),
         jwks_url when is_binary(jwks_url) and jwks_url != "" <- json["jwks_uri"] do
      {:ok, jwks_url}
    else
      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, truncate_body(body)}}

      nil ->
        {:error, :missing_jwks_uri}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_get(url) do
    Req.get(url,
      receive_timeout: @http_timeout_ms,
      connect_options: [timeout: @http_connect_timeout_ms],
      max_redirects: @max_redirects,
      retry: false
    )
  rescue
    e -> {:error, {:request_error, Exception.message(e)}}
  end

  defp validate_url(url) do
    uri = URI.parse(url)
    env = Application.get_env(:cybernetic, :environment, :prod)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, :invalid_scheme}

      env == :prod and uri.scheme != "https" ->
        {:error, :https_required_in_prod}

      uri.host in [nil, ""] ->
        {:error, :missing_host}

      # Block localhost/internal IPs in prod
      env == :prod and internal_host?(uri.host) ->
        {:error, :internal_host_blocked}

      true ->
        :ok
    end
  end

  defp internal_host?(host) do
    host in ["localhost", "127.0.0.1", "0.0.0.0", "::1"] or
      String.starts_with?(host, "192.168.") or
      String.starts_with?(host, "10.") or
      String.starts_with?(host, "172.16.") or
      String.ends_with?(host, ".local")
  end

  defp decode_json(body) when is_binary(body) do
    Jason.decode(body)
  end

  defp decode_json(body) when is_map(body), do: {:ok, body}

  defp build_keys_map(keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case key do
        %{"kid" => kid} when is_binary(kid) ->
          Map.put(acc, kid, JOSE.JWK.from_map(key))

        _ ->
          acc
      end
    end)
  end

  defp truncate_body(body) when is_binary(body) and byte_size(body) > 500 do
    String.slice(body, 0, 500) <> "..."
  end

  defp truncate_body(body), do: body

  defp cache_ttl_ms do
    Application.get_env(:cybernetic, :oidc, [])
    |> Keyword.get(:jwk_cache_ttl_ms, @default_ttl_ms)
  end
end
