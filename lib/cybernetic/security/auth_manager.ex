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
  alias Cybernetic.Security.{AuditLogger, Crypto}
  alias Cybernetic.Core.CRDT.ContextGraph
  
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
  @jwt_secret System.get_env("JWT_SECRET", "dev-secret-change-in-production")
  @jwt_algorithm :HS256
  @jwt_ttl_seconds 3600 # 1 hour
  @refresh_ttl_seconds 86400 # 24 hours
  
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
    # Initialize ETS tables for session and API key storage
    :ets.new(:auth_sessions, [:set, :public, :named_table])
    :ets.new(:api_keys, [:set, :public, :named_table])
    :ets.new(:refresh_tokens, [:set, :public, :named_table])
    
    # Load API keys from config/env
    load_api_keys()
    
    # Start session cleanup timer
    Process.send_after(self(), :cleanup_sessions, 60_000)
    
    state = %{
      sessions: %{},
      api_keys: %{},
      refresh_tokens: %{},
      failed_attempts: %{}, # Track failed auth attempts
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
        case verify_credentials(username, password) do
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
            
            # Audit log
            AuditLogger.log(:auth_success, %{
              user: username,
              method: :password,
              ip: get_caller_ip()
            })
            
            # Emit telemetry
            :telemetry.execute(
              [:cybernetic, :auth, :login],
              %{count: 1},
              %{user: username, method: :password}
            )
            
            {:reply, {:ok, %{token: jwt, refresh_token: refresh, expires_in: @jwt_ttl_seconds}}, state}
          
          {:error, reason} ->
            # Track failed attempt
            state = track_failed_attempt(username, state)
            
            AuditLogger.log(:auth_failure, %{
              user: username,
              reason: reason,
              ip: get_caller_ip()
            })
            
            {:reply, {:error, :invalid_credentials}, state}
        end
      
      {:error, :rate_limited} ->
        AuditLogger.log(:auth_rate_limited, %{user: username})
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
          
          AuditLogger.log(:api_key_auth, %{
            key_name: key_data.name,
            success: true
          })
          
          {:reply, {:ok, auth_context}, state}
        else
          AuditLogger.log(:api_key_expired, %{key_name: key_data.name})
          {:reply, {:error, :expired_key}, state}
        end
      
      [] ->
        AuditLogger.log(:api_key_invalid, %{})
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
        # Try to verify JWT signature even if not in session cache
        case verify_jwt(token) do
          {:ok, claims} ->
            auth_context = %{
              user_id: claims["sub"],
              roles: claims["roles"] || [],
              permissions: expand_permissions(claims["roles"] || []),
              metadata: %{auth_method: :jwt}
            }
            {:reply, {:ok, auth_context}, state}
          
          {:error, _reason} ->
            {:reply, {:error, :invalid_token}, state}
        end
    end
  end
  
  @impl true
  def handle_call({:refresh_token, refresh_token}, _from, state) do
    case :ets.lookup(:refresh_tokens, refresh_token) do
      [{^refresh_token, user_id}] ->
        # Generate new tokens
        user = get_user(user_id)
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
        
        AuditLogger.log(:token_refreshed, %{user_id: user_id})
        
        {:reply, {:ok, %{token: new_jwt, refresh_token: new_refresh, expires_in: @jwt_ttl_seconds}}, state}
      
      [] ->
        {:reply, {:error, :invalid_refresh_token}, state}
    end
  end
  
  @impl true
  def handle_call({:authorize, auth_context, resource, action}, _from, state) do
    authorized? = 
      case auth_context.permissions do
        [:all | _] -> true
        permissions -> 
          # Check specific resource/action authorization
          check_permission(permissions, resource, action) ||
          # Check if user has the specific action permission
          action in permissions
      end
    
    if authorized? do
      AuditLogger.log(:authorization, %{
        user_id: auth_context.user_id,
        resource: resource,
        action: action,
        result: :granted
      })
      
      {:reply, :ok, state}
    else
      AuditLogger.log(:authorization, %{
        user_id: auth_context.user_id,
        resource: resource,
        action: action,
        result: :denied
      })
      
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
        nil -> DateTime.add(DateTime.utc_now(), 365 * 24 * 3600, :second) # 1 year default
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
    
    AuditLogger.log(:api_key_created, %{
      name: name,
      roles: roles,
      expires_at: expires_at
    })
    
    {:reply, {:ok, key}, state}
  end
  
  @impl true
  def handle_call({:revoke, token_or_key}, _from, state) do
    # Try as JWT token first
    case :ets.lookup(:auth_sessions, token_or_key) do
      [{^token_or_key, session}] ->
        :ets.delete(:auth_sessions, token_or_key)
        :ets.delete(:refresh_tokens, session.refresh_token)
        
        AuditLogger.log(:token_revoked, %{user_id: session.user_id})
        {:reply, :ok, state}
      
      [] ->
        # Try as API key
        key_hash = hash_api_key(token_or_key)
        case :ets.lookup(:api_keys, key_hash) do
          [{^key_hash, key_data}] ->
            :ets.delete(:api_keys, key_hash)
            
            AuditLogger.log(:api_key_revoked, %{name: key_data.name})
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
    cutoff = DateTime.add(now, -30 * 24 * 3600, :second)
    
    :ets.tab2list(:refresh_tokens)
    |> Enum.each(fn {token, _user_id} ->
      # In production, store creation time with refresh tokens
      # For now, we'll keep them until explicitly revoked
      :ok
    end)
    
    # Reset rate limit counters older than 1 hour
    state = %{state | 
      failed_attempts: clean_old_attempts(state.failed_attempts),
      rate_limits: %{}
    }
    
    # Schedule next cleanup
    Process.send_after(self(), :cleanup_sessions, 60_000)
    
    {:noreply, state}
  end
  
  # ========== PRIVATE FUNCTIONS ==========
  
  defp verify_credentials(username, password) do
    # In production, check against secure password store with bcrypt
    # For demo, using hardcoded users
    users = %{
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
  
  defp generate_jwt(user) do
    claims = %{
      "sub" => user.id,
      "username" => user.username,
      "roles" => user.roles,
      "iat" => DateTime.to_unix(DateTime.utc_now()),
      "exp" => DateTime.to_unix(DateTime.add(DateTime.utc_now(), @jwt_ttl_seconds, :second))
    }
    
    # In production, use proper JWT library like Joken
    # For now, simple encoded JSON with signature
    payload = Jason.encode!(claims)
    signature = :crypto.mac(:hmac, :sha256, @jwt_secret, payload) |> Base.encode64()
    
    Base.encode64(payload) <> "." <> signature
  end
  
  defp verify_jwt(token) do
    case String.split(token, ".") do
      [payload_b64, signature_b64] ->
        payload = Base.decode64!(payload_b64)
        expected_signature = :crypto.mac(:hmac, :sha256, @jwt_secret, payload) |> Base.encode64()
        
        if signature_b64 == expected_signature do
          claims = Jason.decode!(payload)
          
          # Check expiration
          if claims["exp"] > DateTime.to_unix(DateTime.utc_now()) do
            {:ok, claims}
          else
            {:error, :expired}
          end
        else
          {:error, :invalid_signature}
        end
      
      _ ->
        {:error, :invalid_format}
    end
  end
  
  defp generate_refresh_token(user) do
    :crypto.strong_rand_bytes(32) |> Base.encode64()
  end
  
  defp generate_api_key do
    "cyb_" <> (:crypto.strong_rand_bytes(32) |> Base.encode64(padding: false))
  end
  
  defp hash_api_key(key) do
    :crypto.hash(:sha256, key) |> Base.encode16()
  end
  
  defp hash_password(password) do
    # In production, use Argon2 or bcrypt
    :crypto.hash(:sha256, password <> "salt") |> Base.encode16()
  end
  
  defp verify_password(password, hash) do
    hash_password(password) == hash
  end
  
  defp expand_permissions(roles) do
    roles
    |> Enum.flat_map(fn role ->
      Map.get(@role_permissions, role, [])
    end)
    |> Enum.uniq()
  end
  
  defp check_permission(permissions, resource, action) do
    # Resource-specific permission checking
    # Format: "resource:action"
    specific_permission = :"#{resource}:#{action}"
    specific_permission in permissions
  end
  
  defp check_rate_limit(username, state) do
    attempts = Map.get(state.failed_attempts, username, [])
    recent_attempts = 
      attempts
      |> Enum.filter(fn time ->
        DateTime.diff(DateTime.utc_now(), time, :second) < 300 # 5 minutes
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
      filtered = Enum.filter(attempts, fn time ->
        DateTime.compare(time, cutoff) == :gt
      end)
      {username, filtered}
    end)
    |> Enum.reject(fn {_username, attempts} -> Enum.empty?(attempts) end)
    |> Map.new()
  end
  
  defp get_user(user_id) do
    # In production, fetch from database
    %{
      id: user_id,
      username: "user",
      roles: [:operator]
    }
  end
  
  defp get_caller_ip do
    # In production, extract from connection metadata
    "127.0.0.1"
  end
  
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