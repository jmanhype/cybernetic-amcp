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
  # alias Cybernetic.Security.Crypto  # Not used yet
  # alias Cybernetic.Core.CRDT.ContextGraph  # Not used yet

  @type role :: :admin | :operator | :viewer | :agent | :system
  @type permission :: atom()
  @type auth_token :: String.t()
  @type api_key :: String.t()
  @type user_id :: String.t()

  @type auth_context :: %{
          user_id: user_id(),
          roles: [role()],
          permissions: [permission()],
          metadata: map()
        }

  # JWT configuration
  # P0 Fix: Read JWT secret at runtime, not compile time
  # @jwt_algorithm :HS256  # Not used yet
  # 1 hour
  @jwt_ttl_seconds 3600
  # @refresh_ttl_seconds 86400 # 24 hours  # Not used yet

  # P0 Security: Get JWT secret at runtime from environment
  defp get_jwt_secret do
    System.get_env("JWT_SECRET", "dev-secret-change-in-production")
  end

  # Role definitions with permissions
  @role_permissions %{
    admin: [:all],
    operator: [:read, :write, :execute, :monitor],
    viewer: [:read, :monitor],
    agent: [:read, :write, :execute_limited],
    system: [:all, :internal]
  }

  @doc """
  Starts the Authentication Manager
  """
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

    # Load API keys from config/env
    load_api_keys()

    # Start session cleanup timer
    Process.send_after(self(), :cleanup_sessions, 60_000)

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
  Authenticate with username/password and get JWT token
  """
  def authenticate(username, password) do
    GenServer.call(__MODULE__, {:authenticate, username, password})
  end

  @doc """
  Authenticate with API key
  """
  def authenticate_api_key(api_key) do
    GenServer.call(__MODULE__, {:authenticate_api_key, api_key})
  end

  @doc """
  Validate JWT token and return auth context
  """
  def validate_token(token) do
    GenServer.call(__MODULE__, {:validate_token, token})
  end

  @doc """
  Refresh an expired token using refresh token
  """
  def refresh_token(refresh_token) do
    GenServer.call(__MODULE__, {:refresh_token, refresh_token})
  end

  @doc """
  Authorize an action based on auth context
  """
  def authorize(auth_context, resource, action) do
    GenServer.call(__MODULE__, {:authorize, auth_context, resource, action})
  end

  @doc """
  Create a new API key with specified permissions
  """
  def create_api_key(name, roles, opts \\ []) do
    GenServer.call(__MODULE__, {:create_api_key, name, roles, opts})
  end

  @doc """
  Revoke an API key or JWT token
  """
  def revoke(token_or_key) do
    GenServer.call(__MODULE__, {:revoke, token_or_key})
  end

  @doc """
  List active sessions
  """
  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions)
  end

  # ========== CALLBACKS ==========

  @impl true
  def handle_call({:authenticate, username, password}, _from, state) do
    # Check rate limiting
    case check_rate_limit(username, state) do
      {:ok, state} ->
        # Verify credentials (in production, check against secure store)
        case verify_credentials(username, password, state.users) do
          {:ok, user} ->
            # Generate tokens
            jwt = generate_jwt(user)
            refresh = generate_refresh_token(user)

            # Store session
            session = %{
              user_id: user.id,
              username: username,
              roles: user.roles,
              jwt: jwt,
              refresh_token: refresh,
              created_at: DateTime.utc_now(),
              expires_at: DateTime.add(DateTime.utc_now(), @jwt_ttl_seconds, :second)
            }

            :ets.insert(:auth_sessions, {jwt, session})
            :ets.insert(:refresh_tokens, {refresh, user.id})

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

            # Audit log (disabled for now)
            Logger.warning("Authentication failed for #{username}: #{reason}")

            {:reply, {:error, :invalid_credentials}, state}
        end

      {:error, :rate_limited} ->
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
            metadata: %{auth_method: :api_key}
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

  @impl true
  def handle_call({:validate_token, token}, _from, state) do
    case :ets.lookup(:auth_sessions, token) do
      [{^token, session}] ->
        # Check expiration
        if DateTime.compare(DateTime.utc_now(), session.expires_at) == :lt do
          auth_context = %{
            user_id: session.user_id,
            roles: session.roles,
            permissions: expand_permissions(session.roles),
            metadata: %{
              username: session.username,
              auth_method: :jwt
            }
          }

          {:reply, {:ok, auth_context}, state}
        else
          # Token expired
          :ets.delete(:auth_sessions, token)
          {:reply, {:error, :token_expired}, state}
        end

      [] ->
        # Not a local session token; try verifying it as a real JWT (OIDC/JWKS).
        case Cybernetic.Security.JWT.verify(token) do
          {:ok, claims} ->
            {:reply, {:ok, auth_context_from_claims(claims)}, state}

          {:error, :token_expired} ->
            {:reply, {:error, :token_expired}, state}

          _ ->
            {:reply, {:error, :invalid_token}, state}
        end
    end
  end

  @impl true
  def handle_call({:refresh_token, refresh_token}, _from, state) do
    case :ets.lookup(:refresh_tokens, refresh_token) do
      [{^refresh_token, user_id}] ->
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
        :ets.insert(:refresh_tokens, {new_refresh, user_id})

        session = %{
          user_id: user.id,
          username: user.username,
          roles: user.roles,
          jwt: new_jwt,
          refresh_token: new_refresh,
          created_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), @jwt_ttl_seconds, :second)
        }

        :ets.insert(:auth_sessions, {new_jwt, session})

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
        nil -> DateTime.add(DateTime.utc_now(), 365 * 24 * 3600, :second)
        seconds -> DateTime.add(DateTime.utc_now(), seconds, :second)
      end

    key_data = %{
      name: name,
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
    # Remove expired sessions
    now = DateTime.utc_now()

    :ets.tab2list(:auth_sessions)
    |> Enum.each(fn {token, session} ->
      if DateTime.compare(now, session.expires_at) == :gt do
        :ets.delete(:auth_sessions, token)
        :ets.delete(:refresh_tokens, session.refresh_token)

        Logger.debug("Cleaned up expired session for user: #{session.user_id}")
      end
    end)

    # Clean up old refresh tokens (older than 30 days)
    _cutoff = DateTime.add(now, -30 * 24 * 3600, :second)

    :ets.tab2list(:refresh_tokens)
    |> Enum.each(fn {_token, _user_id} ->
      # In production, store creation time with refresh tokens
      # For now, we'll keep them until explicitly revoked
      :ok
    end)

    # Reset rate limit counters older than 1 hour
    state = %{
      state
      | failed_attempts: clean_old_attempts(state.failed_attempts),
        rate_limits: %{}
    }

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_sessions, 60_000)

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

  # Unused function - kept for future JWT validation needs
  # defp verify_jwt(token) do
  #   case String.split(token, ".") do
  #     [payload_b64, signature_b64] ->
  #       case Base.decode64(payload_b64, padding: false) do
  #         {:ok, payload} ->
  #           expected_signature = :crypto.mac(:hmac, :sha256, @jwt_secret, payload) |> Base.encode64(padding: false)
  #       
  #           if signature_b64 == expected_signature do
  #             claims = Jason.decode!(payload)
  #             
  #             # Check expiration
  #             if claims["exp"] > DateTime.to_unix(DateTime.utc_now()) do
  #               {:ok, claims}
  #             else
  #               {:error, :expired}
  #             end
  #           else
  #             {:error, :invalid_signature}
  #           end
  #         
  #         :error ->
  #           {:error, :invalid_format}
  #       end
  #     
  #     _ ->
  #       {:error, :invalid_format}
  #   end
  # end

  defp generate_refresh_token(_user) do
    :crypto.strong_rand_bytes(32) |> Base.encode64()
  end

  defp generate_api_key do
    "cyb_" <> (:crypto.strong_rand_bytes(32) |> Base.encode64(padding: false))
  end

  defp hash_api_key(key) do
    :crypto.hash(:sha256, key) |> Base.encode16()
  end

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

    %{
      user_id: claims["sub"] || claims["user_id"] || claims["uid"] || "unknown",
      roles: roles,
      permissions: expand_permissions(roles),
      metadata: %{
        username: claims["username"] || claims["preferred_username"] || claims["email"],
        tenant_id: claims["tenant_id"] || claims["tid"],
        auth_method: :jwt
      }
    }
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
        DateTime.diff(DateTime.utc_now(), time, :second) < 300
      end)

    if length(recent_attempts) >= 5 do
      {:error, :rate_limited}
    else
      {:ok, state}
    end
  end

  defp track_failed_attempt(username, state) do
    attempts = Map.get(state.failed_attempts, username, [])
    new_attempts = [DateTime.utc_now() | attempts] |> Enum.take(10)

    %{state | failed_attempts: Map.put(state.failed_attempts, username, new_attempts)}
  end

  defp clean_old_attempts(failed_attempts) do
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

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

  # Unused function - kept for future IP tracking needs
  # defp get_caller_ip do
  #   # In production, extract from connection metadata
  #   "127.0.0.1"
  # end

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
        expires_at: DateTime.add(DateTime.utc_now(), 10 * 365 * 24 * 3600, :second),
        metadata: %{source: "env"}
      }

      :ets.insert(:api_keys, {key_hash, key_data})
      Logger.info("Loaded system API key from environment")
    end
  end
end
