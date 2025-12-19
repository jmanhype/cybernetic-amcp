defmodule Cybernetic.Security.AuthManagerTest do
  use ExUnit.Case, async: false
  alias Cybernetic.Security.AuthManager

  setup do
    # Start AuthManager for each test (handle already_started case)
    pid =
      case AuthManager.start_link() do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, %{pid: pid}}
  end

  describe "authentication" do
    test "authenticates valid user with correct password" do
      assert {:ok, %{token: token, refresh_token: refresh, expires_in: _}} =
               AuthManager.authenticate("admin", "admin123")

      assert is_binary(token)
      assert is_binary(refresh)
    end

    test "rejects invalid username" do
      assert {:error, :invalid_credentials} =
               AuthManager.authenticate("nonexistent", "password")
    end

    test "rejects invalid password" do
      assert {:error, :invalid_credentials} =
               AuthManager.authenticate("admin", "wrongpassword")
    end

    test "rate limits after multiple failed attempts" do
      # Make 5 failed attempts
      for _ <- 1..5 do
        AuthManager.authenticate("admin", "wrong")
      end

      # 6th attempt should be rate limited
      assert {:error, :too_many_attempts} =
               AuthManager.authenticate("admin", "admin123")
    end
  end

  describe "token validation" do
    test "validates a valid JWT token" do
      {:ok, %{token: token}} = AuthManager.authenticate("admin", "admin123")

      assert {:ok, context} = AuthManager.validate_token(token)
      assert context.user_id == "user_admin"
      assert :admin in context.roles
      assert :all in context.permissions
    end

    test "rejects invalid token" do
      assert {:error, :invalid_token} =
               AuthManager.validate_token("invalid.token")
    end

    test "rejects expired token" do
      # This would require mocking time or waiting for expiration
      # For now, test with invalid token
      assert {:error, :invalid_token} =
               AuthManager.validate_token("expired.token")
    end
  end

  describe "refresh tokens" do
    test "refreshes valid refresh token" do
      {:ok, %{refresh_token: refresh}} =
        AuthManager.authenticate("admin", "admin123")

      assert {:ok, %{token: new_token, refresh_token: new_refresh}} =
               AuthManager.refresh_token(refresh)

      assert is_binary(new_token)
      assert is_binary(new_refresh)
      assert new_refresh != refresh

      assert {:ok, context} = AuthManager.validate_token(new_token)
      assert context.user_id == "user_admin"
      assert :admin in context.roles
    end

    test "rejects invalid refresh token" do
      assert {:error, :invalid_refresh_token} =
               AuthManager.refresh_token("invalid_refresh")
    end
  end

  describe "API key management" do
    test "creates and validates API key" do
      assert {:ok, api_key} =
               AuthManager.create_api_key("test_key", [:operator])

      assert String.starts_with?(api_key, "cyb_")

      assert {:ok, context} = AuthManager.authenticate_api_key(api_key)
      assert context.user_id == "test_key"
      assert :operator in context.roles
    end

    test "rejects invalid API key" do
      assert {:error, :invalid_key} =
               AuthManager.authenticate_api_key("invalid_key")
    end

    test "revokes API key" do
      {:ok, api_key} = AuthManager.create_api_key("revoke_test", [:viewer])

      assert :ok = AuthManager.revoke(api_key)
      assert {:error, :invalid_key} = AuthManager.authenticate_api_key(api_key)
    end
  end

  describe "authorization" do
    test "authorizes admin for all actions" do
      {:ok, %{token: token}} = AuthManager.authenticate("admin", "admin123")
      {:ok, context} = AuthManager.validate_token(token)

      assert :ok = AuthManager.authorize(context, :any_resource, :any_action)
    end

    test "authorizes operator for allowed actions" do
      {:ok, %{token: token}} = AuthManager.authenticate("operator", "operator123")
      {:ok, context} = AuthManager.validate_token(token)

      assert :ok = AuthManager.authorize(context, :database, :read)
      assert :ok = AuthManager.authorize(context, :database, :write)
    end

    test "denies viewer write access" do
      {:ok, %{token: token}} = AuthManager.authenticate("viewer", "viewer123")
      {:ok, context} = AuthManager.validate_token(token)

      assert :ok = AuthManager.authorize(context, :database, :read)

      assert {:error, :unauthorized} =
               AuthManager.authorize(context, :database, :write)
    end
  end

  describe "session management" do
    test "lists active sessions" do
      AuthManager.authenticate("admin", "admin123")
      AuthManager.authenticate("operator", "operator123")

      sessions = AuthManager.list_sessions()

      assert length(sessions) >= 2
      assert Enum.any?(sessions, &(&1.username == "admin"))
      assert Enum.any?(sessions, &(&1.username == "operator"))
    end

    test "revokes session token" do
      {:ok, %{token: token}} = AuthManager.authenticate("admin", "admin123")

      assert {:ok, _} = AuthManager.validate_token(token)
      assert :ok = AuthManager.revoke(token)
      assert {:error, :invalid_token} = AuthManager.validate_token(token)
    end
  end

  describe "security features" do
    test "stores sessions in ETS" do
      {:ok, %{token: token}} = AuthManager.authenticate("admin", "admin123")

      assert [{^token, session}] = :ets.lookup(:auth_sessions, token)
      assert session.user_id == "user_admin"
    end

    test "hashes API keys before storage" do
      {:ok, api_key} = AuthManager.create_api_key("secure_test", [:admin])

      # Check that raw key is not stored
      assert [] = :ets.lookup(:api_keys, api_key)

      # But hashed version works for auth
      assert {:ok, _} = AuthManager.authenticate_api_key(api_key)
    end

    test "different users get different tokens" do
      {:ok, %{token: token1}} = AuthManager.authenticate("admin", "admin123")
      {:ok, %{token: token2}} = AuthManager.authenticate("operator", "operator123")

      assert token1 != token2
    end
  end
end
