defmodule Cybernetic.Security.AuthManager do
  @moduledoc """
  Authentication and Authorization Manager for Cybernetic aMCP Framework.

  Provides:
  - JWT-based authentication
  - API key management
  - Role-Based Access Control (RBAC)
  - Session management
  - Audit logging integration
  """

  use GenServer
  require Logger

  @typedoc "User role for RBAC authorization"
  @type role :: :admin | :operator | :viewer | :agent | :system
  @typedoc "Permission atom for fine-grained access control"
  @type permission :: atom()
  @typedoc "JWT authentication token string"
  @type auth_token :: String.t()
  @typedoc "API key for programmatic access"
  @type api_key :: String.t()
  @typedoc "Unique user identifier"
  @type user_id :: String.t()

  @typedoc "Authentication context returned after successful authentication"
  @type auth_context :: %{
          user_id: user_id(),
          roles: [role()],
          permissions: [permission()],
          metadata: map()
        }

  # ========== CONFIGURATION CONSTANTS ==========
  # JWT configuration - TTL in seconds
  @jwt_ttl_seconds 3600

  # Session cleanup interval in milliseconds
  @cleanup_interval_ms 60_000

  # Rate limiting configuration
  @rate_limit_window_seconds 300
  @max_failed_attempts 5
  @failed_attempts_history_size 10
  @attempt_cleanup_seconds 3600

  # API key expiry (1 year in seconds)
  @api_key_ttl_seconds 365 * 24 * 3600

  # Delegate to centralized Secrets module for consistent validation
  @spec get_jwt_secret() :: String.t()
  defp get_jwt_secret, do: Cybernetic.Security.Secrets.jwt_secret()

  # Role definitions with permissions
  @role_permissions %{
    admin: [:all],
    operator: [:read, :write, :execute, :monitor],
    viewer: [:read, :monitor],
    agent: [:read, :write, :execute_limited],
    system: [:all, :internal]
  }

  @doc """
  Starts the Authentication Manager GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # P0 Security: Use :protected instead of :public to restrict ETS access
    # Only the owning process (this GenServer) can write; other processes can read
    :ets.new(:auth_sessions, [:set, :protected, :named_table, {:read_concurrency, true}])
    :ets.new(:api_keys, [:set, :protected, :named_table, {:read_concurrency, true}])
    :ets.new(:refresh_tokens, [:set, :protected, :named_table, {:read_concurrency, true}])

    # P1 Performance: Expiry index for O(log n) session cleanup instead of O(n) scan
    # Key: {expiry_timestamp, token}, Value: refresh_token (for cleanup)
    :ets.new(:auth_session_expiry, [:ordered_set, :protected, :named_table])

    # Load API keys from config/env
    load_api_keys()

    # Start session cleanup timer
    Process.send_after(self(), :cleanup_sessions, @cleanup_interval_ms)

    env = Application.get_env(:cybernetic, :environment, :prod)
    users = load_users(env)
    users_by_id = Map.new(users, fn {_username, user} -> {user.id, user} end)

    state = %{
      sessions: %{},
      api_keys: %{},
      refresh_tokens: %{},
      users: users,
      users_by_id: users_by_id,
      # Track failed auth attempts
      failed_attempts: %{},
      rate_limits: %{}
    }

    Logger.info("AuthManager started with JWT auth and RBAC")

    {:ok, state}
  end

  # ========== PUBLIC API ==========

  @doc """
  Authenticate with username/password and get JWT token.

  Optionally accepts a tenant_id to associate with the session.
  In production, tenant_id should be provided for proper tenant isolation.
  """
  @spec authenticate(String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def authenticate(username, password, tenant_id \\ nil) do
    GenServer.call(__MODULE__, {:authenticate, username, password, tenant_id})
  end

  @doc """
  Authenticate with API key.
  """
  @spec authenticate_api_key(String.t()) :: {:ok, auth_context()} | {:error, atom()}
  def authenticate_api_key(api_key) do
    GenServer.call(__MODULE__, {:authenticate_api_key, api_key})
  end

  @doc """
  Validate JWT token and return auth context.

  Uses direct ETS read for session tokens (fast path), falling back to
  GenServer call for JWT verification (slow path). This allows high throughput
  for repeated validations of the same session token.
  """
  @spec validate_token(String.t()) :: {:ok, auth_context()} | {:error, atom()}
  def validate_token(token) do
    # Guard: ensure ETS table exists (handles startup/restart race)
    case :ets.whereis(:auth_sessions) do
      :undefined ->
        # Table not ready - fall back to GenServer (will queue until init completes)
        GenServer.call(__MODULE__, {:validate_external_token, token})

      _tid ->
        validate_token_fast_path(token)
    end
  end

  defp validate_token_fast_path(token) do
    # Fast path: direct ETS read for session tokens
    case :ets.lookup(:auth_sessions, token) do
      [{^token, session}] ->
        if DateTime.compare(DateTime.utc_now(), session.expires_at) == :lt do
          {:ok,
           %{
             user_id: session.user_id,
             roles: session.roles,
             permissions: expand_permissions(session.roles),
             metadata: %{
               username: session.username,
               tenant_id: Map.get(session, :tenant_id),
               auth_method: :jwt
             }
           }}
        else
          # Expired - need GenServer to delete from ETS
          GenServer.call(__MODULE__, {:validate_expired_token, token})
        end

      [] ->
        # Not in ETS - need GenServer for JWT verification (may need rate limiting)
        GenServer.call(__MODULE__, {:validate_external_token, token})
    end
  end

  @doc """
  Refresh an expired token using refresh token.
  """
  @spec refresh_token(String.t()) :: {:ok, map()} | {:error, atom()}
  def refresh_token(refresh_token) do
    GenServer.call(__MODULE__, {:refresh_token, refresh_token})
  end

  @doc """
  Authorize an action based on auth context.
  """
  @spec authorize(auth_context(), atom(), atom()) :: :ok | {:error, :unauthorized}
  def authorize(auth_context, resource, action) do
    GenServer.call(__MODULE__, {:authorize, auth_context, resource, action})
  end

  @doc """
  Create a new API key with specified permissions.
  """
  @spec create_api_key(String.t(), [role()], keyword()) :: {:ok, String.t()}
  def create_api_key(name, roles, opts \\ []) do
    GenServer.call(__MODULE__, {:create_api_key, name, roles, opts})
  end

  @doc """
  Revoke an API key or JWT token.
  """
  @spec revoke(String.t()) :: :ok | {:error, :not_found}
  def revoke(token_or_key) do
    GenServer.call(__MODULE__, {:revoke, token_or_key})
  end

  @doc """
  List active sessions.
  """
  @spec list_sessions() :: [map()]
  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions)
  end

  # ========== CALLBACKS ==========

  @impl true
  def handle_call({:authenticate, username, password, tenant_id}, _from, state) do
    # Check rate limiting
    case check_rate_limit(username, state) do
      {:ok, state} ->
        # Verify credentials (in production, check against secure store)
        case verify_credentials(username, password, state.users) do
          {:ok, user} ->
            # Generate tokens
            jwt = generate_jwt(user)
            refresh = generate_refresh_token(user)

            # Store session with tenant_id for isolation
            session = %{
              user_id: user.id,
              username: username,
              roles: user.roles,
              tenant_id: tenant_id,
              jwt: jwt,
              refresh_token: refresh,
              created_at: DateTime.utc_now(),
              expires_at: DateTime.add(DateTime.utc_now(), @jwt_ttl_seconds, :second)
            }

            :ets.insert(:auth_sessions, {jwt, session})
            :ets.insert(:refresh_tokens, {refresh, {user.id, tenant_id}})
            # P1 Performance: Index by expiry for O(log n) cleanup
            expiry_key = {DateTime.to_unix(session.expires_at), jwt}
            :ets.insert(:auth_session_expiry, {expiry_key, refresh})

            # Audit log (disabled for now)
            Logger.info("User authenticated: #{username}")

            # Emit telemetry
            :telemetry.execute(
              [:cybernetic, :auth, :login],
              %{count: 1},
              %{user: username, method: :password}
            )

            {:reply, {:ok, %{token: jwt, refresh_token: refresh, expires_in: @jwt_ttl_seconds}},
             state}

          {:error, reason} ->
            # Track failed attempt
            state = track_failed_attempt(username, state)

            # Telemetry for security monitoring (attack detection)
            :telemetry.execute(
              [:cybernetic, :auth, :login_failed],
              %{count: 1},
              %{user: username, reason: reason}
            )

            Logger.warning("Authentication failed for #{username}: #{reason}")

            {:reply, {:error, :invalid_credentials}, state}
        end

      {:error, :rate_limited} ->
        # Telemetry for rate limit monitoring (brute force detection)
        :telemetry.execute(
          [:cybernetic, :auth, :rate_limited],
          %{count: 1},
          %{user: username}
        )

        Logger.warning("Rate limited: #{username}")
        {:reply, {:error, :too_many_attempts}, state}
    end
  end

  @impl true
  def handle_call({:authenticate_api_key, api_key}, _from, state) do
    case :ets.lookup(:api_keys, hash_api_key(api_key)) do
      [{_hash, key_data}] ->
        # Check if key is expired
        if DateTime.compare(DateTime.utc_now(), key_data.expires_at) == :lt do
          auth_context = %{
            user_id: key_data.name,
            roles: key_data.roles,
            permissions: expand_permissions(key_data.roles),
            metadata: %{
              tenant_id: Map.get(key_data, :tenant_id),
              auth_method: :api_key
            }
          }

          Logger.info("API key authenticated: #{key_data.name}")

          {:reply, {:ok, auth_context}, state}
        else
          Logger.warning("API key expired: #{key_data.name}")
          {:reply, {:error, :expired_key}, state}
        end

      [] ->
        Logger.warning("Invalid API key attempt")
        {:reply, {:error, :invalid_key}, state}
    end
  end

  # Handle expired token - delete from ETS and return error
  @impl true
  def handle_call({:validate_expired_token, token}, _from, state) do
    :ets.delete(:auth_sessions, token)
    {:reply, {:error, :token_expired}, state}
  end

  # Handle external JWT verification (RS256 only, falls through from fast path)
  @impl true
  def handle_call({:validate_external_token, token}, _from, state) do
    # Not a local session token; try verifying it as an external JWT (RS256 only).
    # HS256 tokens must be in ETS (session tokens don't survive restart).
    case Cybernetic.Security.JWT.verify_external(token) do
      {:ok, claims} ->
        case auth_context_from_claims(claims) do
          {:ok, auth_context} ->
            {:reply, {:ok, auth_context}, state}

          {:error, :missing_sub} ->
            Logger.warning("External JWT missing required sub claim")
            {:reply, {:error, :invalid_token}, state}

          {:error, reason} ->
            Logger.warning("External JWT claims rejected", reason: inspect(reason))
            {:reply, {:error, :invalid_token}, state}
        end

      {:error, :token_expired} ->
        {:reply, {:error, :token_expired}, state}

      {:error, {:unsupported_alg, "HS256"}} ->
        # HS256 session token not in ETS - likely expired or server restarted
        {:reply, {:error, :session_expired}, state}

      _ ->
        {:reply, {:error, :invalid_token}, state}
    end
  end

  @impl true
  def handle_call({:refresh_token, refresh_token}, _from, state) do
    case :ets.lookup(:refresh_tokens, refresh_token) do
      [{^refresh_token, {user_id, tenant_id}}] ->
        # Generate new tokens
        user =
          Map.get(state.users_by_id, user_id) ||
            %{
              id: user_id,
              username: user_id,
              roles: [:viewer]
            }

        new_jwt = generate_jwt(user)
        new_refresh = generate_refresh_token(user)

        # Update sessions
        :ets.delete(:refresh_tokens, refresh_token)
        :ets.insert(:refresh_tokens, {new_refresh, {user_id, tenant_id}})

        session = %{
          user_id: user.id,
          username: user.username,
          roles: user.roles,
          tenant_id: tenant_id,
          jwt: new_jwt,
          refresh_token: new_refresh,
          created_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), @jwt_ttl_seconds, :second)
        }

        :ets.insert(:auth_sessions, {new_jwt, session})
        # P1 Performance: Index by expiry for O(log n) cleanup
        expiry_key = {DateTime.to_unix(session.expires_at), new_jwt}
        :ets.insert(:auth_session_expiry, {expiry_key, new_refresh})

        Logger.info("Token refreshed for user: #{user_id}")

        {:reply,
         {:ok, %{token: new_jwt, refresh_token: new_refresh, expires_in: @jwt_ttl_seconds}},
         state}

      [{^refresh_token, user_id}] ->
        # Backwards-compatible shape: refresh token stored without tenant_id
        tenant_id = nil

        user =
          Map.get(state.users_by_id, user_id) ||
            %{
              id: user_id,
              username: user_id,
              roles: [:viewer]
            }

        new_jwt = generate_jwt(user)
        new_refresh = generate_refresh_token(user)

        :ets.delete(:refresh_tokens, refresh_token)
        :ets.insert(:refresh_tokens, {new_refresh, {user_id, tenant_id}})

        session = %{
          user_id: user.id,
          username: user.username,
          roles: user.roles,
          tenant_id: tenant_id,
          jwt: new_jwt,
          refresh_token: new_refresh,
          created_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), @jwt_ttl_seconds, :second)
        }

        :ets.insert(:auth_sessions, {new_jwt, session})
        expiry_key = {DateTime.to_unix(session.expires_at), new_jwt}
        :ets.insert(:auth_session_expiry, {expiry_key, new_refresh})

        Logger.info("Token refreshed for user: #{user_id}")

        {:reply,
         {:ok, %{token: new_jwt, refresh_token: new_refresh, expires_in: @jwt_ttl_seconds}},
         state}

      [] ->
        {:reply, {:error, :invalid_refresh_token}, state}
    end
  end

  @impl true
  def handle_call({:authorize, auth_context, resource, action}, _from, state) do
    authorized? =
      case auth_context.permissions do
        [:all | _] ->
          true

        permissions ->
          # Check specific resource/action authorization
          # Check if user has the specific action permission
          check_permission(permissions, resource, action) ||
            action in permissions
      end

    if authorized? do
      Logger.debug("Authorization granted: #{auth_context.user_id} -> #{resource}:#{action}")

      {:reply, :ok, state}
    else
      # Telemetry for unauthorized access attempts (security monitoring)
      :telemetry.execute(
        [:cybernetic, :auth, :authorization_denied],
        %{count: 1},
        %{user: auth_context.user_id, resource: resource, action: action}
      )

      Logger.warning("Authorization denied: #{auth_context.user_id} -> #{resource}:#{action}")

      {:reply, {:error, :unauthorized}, state}
    end
  end

  @impl true
  def handle_call({:create_api_key, name, roles, opts}, _from, state) do
    # Generate secure API key
    key = generate_api_key()
    key_hash = hash_api_key(key)

    expires_at =
      case Keyword.get(opts, :expires_in) do
        # 1 year default
        nil -> DateTime.add(DateTime.utc_now(), @api_key_ttl_seconds, :second)
        seconds -> DateTime.add(DateTime.utc_now(), seconds, :second)
      end

    key_data = %{
      name: name,
      tenant_id: Keyword.get(opts, :tenant_id),
      roles: roles,
      created_at: DateTime.utc_now(),
      expires_at: expires_at,
      metadata: Keyword.get(opts, :metadata, %{})
    }

    :ets.insert(:api_keys, {key_hash, key_data})

    Logger.info("API key created: #{name} with roles #{inspect(roles)}")

    {:reply, {:ok, key}, state}
  end

  @impl true
  def handle_call({:revoke, token_or_key}, _from, state) do
    # Try as JWT token first
    case :ets.lookup(:auth_sessions, token_or_key) do
      [{^token_or_key, session}] ->
        :ets.delete(:auth_sessions, token_or_key)
        :ets.delete(:refresh_tokens, session.refresh_token)
        # P1 Performance: Also clean up expiry index
        expiry_key = {DateTime.to_unix(session.expires_at), token_or_key}
        :ets.delete(:auth_session_expiry, expiry_key)

        Logger.info("Token revoked for user: #{session.user_id}")
        {:reply, :ok, state}

      [] ->
        # Try as API key
        key_hash = hash_api_key(token_or_key)

        case :ets.lookup(:api_keys, key_hash) do
          [{^key_hash, key_data}] ->
            :ets.delete(:api_keys, key_hash)

            Logger.info("API key revoked: #{key_data.name}")
            {:reply, :ok, state}

          [] ->
            {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    sessions =
      :ets.tab2list(:auth_sessions)
      |> Enum.map(fn {_token, session} ->
        %{
          user_id: session.user_id,
          username: session.username,
          created_at: session.created_at,
          expires_at: session.expires_at
        }
      end)

    {:reply, sessions, state}
  end

  @impl true
  def handle_info(:cleanup_sessions, state) do
    # P1 Performance: Use expiry index for O(log n) cleanup instead of O(n) scan
    # P2 Resilience: Wrap in try/rescue to prevent cleanup failures from crashing GenServer
    state =
      try do
        now_unix = DateTime.to_unix(DateTime.utc_now())

        # Select all expired entries: keys where expiry_timestamp <= now
        # The :ordered_set is sorted by key, so we select from start to now
        expired =
          :ets.select(
            :auth_session_expiry,
            [{{{:"$1", :"$2"}, :"$3"}, [{:"=<", :"$1", now_unix}], [{{:"$2", :"$3"}}]}]
          )

        # Delete each expired session
        Enum.each(expired, fn {token, refresh_token} ->
          :ets.delete(:auth_sessions, token)
          :ets.delete(:refresh_tokens, refresh_token)
          Logger.debug("Cleaned up expired session", token_prefix: String.slice(token, 0, 8))
        end)

        # Delete from expiry index using range delete
        if length(expired) > 0 do
          :ets.select_delete(
            :auth_session_expiry,
            [{{{:"$1", :_}, :_}, [{:"=<", :"$1", now_unix}], [true]}]
          )

          Logger.debug("Session cleanup complete", expired_count: length(expired))
        end

        # Reset rate limit counters older than 1 hour
        %{
          state
          | failed_attempts: clean_old_attempts(state.failed_attempts),
            rate_limits: %{}
        }
      rescue
        e ->
          Logger.error("Session cleanup failed, will retry next interval", 
            error: inspect(e), 
            stacktrace: Exception.format_stacktrace(__STACKTRACE__))
          state
      end

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_sessions, @cleanup_interval_ms)

    {:noreply, state}
  end

  # ========== PRIVATE FUNCTIONS ==========

  defp verify_credentials(username, password, users) when is_map(users) do
    case Map.get(users, username) do
      nil ->
        {:error, :user_not_found}

      user ->
        if verify_password(password, user.password_hash) do
          {:ok, user}
        else
          {:error, :invalid_password}
        end
    end
  end

  defp load_users(env) do
    users = get_configured_users()

    if map_size(users) == 0 and env in [:dev, :test] do
      %{
        "admin" => %{
          id: "user_admin",
          username: "admin",
          password_hash: hash_password("admin123"),
          roles: [:admin]
        },
        "operator" => %{
          id: "user_operator",
          username: "operator",
          password_hash: hash_password("operator123"),
          roles: [:operator]
        },
        "viewer" => %{
          id: "user_viewer",
          username: "viewer",
          password_hash: hash_password("viewer123"),
          roles: [:viewer]
        }
      }
    else
      users
    end
  end

  defp generate_jwt(user) do
    claims = %{
      "sub" => user.id,
      "username" => user.username,
      "roles" => user.roles,
      "iat" => DateTime.to_unix(DateTime.utc_now()),
      "exp" => DateTime.to_unix(DateTime.add(DateTime.utc_now(), @jwt_ttl_seconds, :second))
    }

    jwk = JOSE.JWK.from_oct(get_jwt_secret())

    jwk
    |> JOSE.JWT.sign(%{"alg" => "HS256"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end


  defp generate_refresh_token(_user) do
    :crypto.strong_rand_bytes(32) |> Base.encode64()
  end

  defp generate_api_key do
    "cyb_" <> (:crypto.strong_rand_bytes(32) |> Base.encode64(padding: false))
  end

  defp hash_api_key(key) do
    # Use HMAC-SHA256 with a secret (keyed hash prevents rainbow table attacks)
    hmac_secret = get_hmac_secret()
    :crypto.mac(:hmac, :sha256, hmac_secret, key) |> Base.encode16()
  end

  # Delegate to centralized Secrets module for consistent validation
  defp get_hmac_secret, do: Cybernetic.Security.Secrets.hmac_secret()

  defp hash_password(password) do
    pepper = System.get_env("PASSWORD_SALT", "")
    opts = argon2_opts()
    Argon2.hash_pwd_salt(password <> pepper, opts)
  end

  defp verify_password(password, hash) do
    pepper = System.get_env("PASSWORD_SALT", "")
    Argon2.verify_pass(password <> pepper, hash)
  end

  # Argon2 params from config or secure defaults
  # See: https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
  # Note: m_cost is 2^N KiB (16 = 64MB, 17 = 128MB)
  defp argon2_opts do
    config = Application.get_env(:cybernetic, :argon2, [])

    [
      # Time cost (iterations) - higher is more secure but slower
      t_cost: Keyword.get(config, :t_cost, 3),
      # Memory cost as power of 2 (2^16 = 64MB, 2^17 = 128MB)
      m_cost: Keyword.get(config, :m_cost, 16),
      # Parallelism - number of threads
      parallelism: Keyword.get(config, :parallelism, 4)
    ]
  end

  defp expand_permissions(roles) do
    roles
    |> Enum.flat_map(fn role ->
      Map.get(@role_permissions, role, [])
    end)
    |> Enum.uniq()
  end

  defp auth_context_from_claims(claims) when is_map(claims) do
    sub = claims["sub"]

    if not (is_binary(sub) and sub != "") do
      {:error, :missing_sub}
    else
      roles =
        case claims["roles"] do
          roles when is_list(roles) ->
            roles
            |> Enum.map(&to_string/1)
            |> Enum.map(&String.downcase/1)
            |> Enum.map(&parse_role/1)
            |> Enum.reject(&is_nil/1)

          role when is_binary(role) ->
            role
            |> String.split(",", trim: true)
            |> Enum.map(&String.downcase/1)
            |> Enum.map(&parse_role/1)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end

      roles = if roles == [], do: [:viewer], else: roles

      # Type-safe extraction of username (validate all sources are strings)
      username = extract_string_claim(claims, ["username", "preferred_username", "email"])
      tenant_id = extract_string_claim(claims, ["tenant_id", "tid"])

      {:ok,
       %{
         user_id: sub,
         roles: roles,
         permissions: expand_permissions(roles),
         metadata: %{
           username: username,
           tenant_id: tenant_id,
           auth_method: :jwt
         }
       }}
    end
  end

  # Extract a string claim from multiple possible keys, validating type
  @spec extract_string_claim(map(), [String.t()]) :: String.t() | nil
  defp extract_string_claim(claims, keys) when is_map(claims) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(claims, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp check_permission(permissions, resource, action) do
    # Resource-specific permission checking
    # Format: "resource:action"
    permission_atom =
      try do
        String.to_existing_atom("#{resource}:#{action}")
      rescue
        ArgumentError -> nil
      end

    permission_atom != nil and permission_atom in permissions
  end

  defp check_rate_limit(username, state) do
    attempts = Map.get(state.failed_attempts, username, [])

    recent_attempts =
      attempts
      |> Enum.filter(fn time ->
        # 5 minutes
        DateTime.diff(DateTime.utc_now(), time, :second) < @rate_limit_window_seconds
      end)

    if length(recent_attempts) >= @max_failed_attempts do
      {:error, :rate_limited}
    else
      {:ok, state}
    end
  end

  defp track_failed_attempt(username, state) do
    attempts = Map.get(state.failed_attempts, username, [])
    new_attempts = [DateTime.utc_now() | attempts] |> Enum.take(@failed_attempts_history_size)

    %{state | failed_attempts: Map.put(state.failed_attempts, username, new_attempts)}
  end

  defp clean_old_attempts(failed_attempts) do
    cutoff = DateTime.add(DateTime.utc_now(), -@attempt_cleanup_seconds, :second)

    failed_attempts
    |> Enum.map(fn {username, attempts} ->
      filtered =
        Enum.filter(attempts, fn time ->
          DateTime.compare(time, cutoff) == :gt
        end)

      {username, filtered}
    end)
    |> Enum.reject(fn {_username, attempts} -> Enum.empty?(attempts) end)
    |> Map.new()
  end

  defp get_configured_users do
    # Load users from environment variables
    # Format: CYBERNETIC_USER_<USERNAME>=<password>:<role1,role2>
    # Example: CYBERNETIC_USER_ADMIN=secure_pass:admin,operator

    System.get_env()
    |> Enum.filter(fn {key, _value} -> String.starts_with?(key, "CYBERNETIC_USER_") end)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      username = String.replace(key, "CYBERNETIC_USER_", "") |> String.downcase()

      case String.split(value, ":", parts: 2) do
        [password, roles_str] ->
          roles =
            roles_str
            |> String.split(",", trim: true)
            |> Enum.map(&String.downcase/1)
            |> Enum.map(&parse_role/1)
            |> Enum.reject(&is_nil/1)

          if roles == [] do
            Logger.warning("No valid roles configured for #{key}")
            acc
          else
            user = %{
              id: "user_#{username}",
              username: username,
              password_hash: hash_password(password),
              roles: roles
            }

            Map.put(acc, username, user)
          end

        _ ->
          Logger.warning("Invalid user config format for #{key}")
          acc
      end
    end)
  end

  defp parse_role("admin"), do: :admin
  defp parse_role("operator"), do: :operator
  defp parse_role("viewer"), do: :viewer
  defp parse_role("agent"), do: :agent
  defp parse_role("system"), do: :system
  defp parse_role(_), do: nil

  defp load_api_keys do
    # Load any pre-configured API keys from environment
    if key = System.get_env("CYBERNETIC_SYSTEM_API_KEY") do
      key_hash = hash_api_key(key)

      key_data = %{
        name: "system",
        roles: [:system],
        created_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 10 * @api_key_ttl_seconds, :second),
        metadata: %{source: "env"}
      }

      :ets.insert(:api_keys, {key_hash, key_data})
      Logger.info("Loaded system API key from environment")
    end
  end
end
