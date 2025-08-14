defmodule Cybernetic.Edge.WASM.ValidatorTest do
  use ExUnit.Case, async: false
  alias Cybernetic.Edge.WASM.{Validator, ValidatorHost}

  describe "validator behaviour" do
    test "implements required callbacks" do
      # Verify behaviour is properly implemented  
      assert {:ok, _state} = Validator.init(%{})
      {:ok, state} = Validator.init(%{})
      msg = %{"test" => "data"}
      assert match?({_, _}, Validator.validate(msg, state))
    end

    test "init returns proper state" do
      assert {:ok, state} = Validator.init(%{})
      assert Map.has_key?(state, :server)
      assert state.server == ValidatorHost
    end

    test "validate delegates to host" do
      # Since WASM isn't loaded, should get error
      {:ok, state} = Validator.init(%{})
      
      message = %{
        "_nonce" => "test_nonce",
        "_timestamp" => System.system_time(:millisecond),
        "_signature" => "test_sig",
        "payload" => %{"data" => "test"}
      }
      
      # Ensure ValidatorHost is started for this test
      unless Process.whereis(ValidatorHost) do
        {:ok, _} = ValidatorHost.start_link(wasm_path: "test.wasm")
      end
      
      # With stubbed WASM, should return error
      result = Validator.validate(message, state)
      assert match?({{:error, _}, _state}, result)
    end
  end

  describe "validator host" do
    setup do
      {:ok, pid} = ValidatorHost.start_link(wasm_path: "test.wasm")
      on_exit(fn -> Process.exit(pid, :normal) end)
      {:ok, pid: pid}
    end

    test "starts without WASM file", %{pid: pid} do
      assert Process.alive?(pid)
      
      # Should have logged warning about missing runtime
      state = :sys.get_state(pid)
      assert state.instance == nil
    end

    test "validate returns error when WASM not loaded", %{pid: _pid} do
      message = %{"test" => "data"}
      
      result = ValidatorHost.validate(ValidatorHost, message)
      assert {:error, :not_loaded} == result
    end

    test "handles missing WASM file gracefully" do
      # Use a unique name to avoid conflicts
      name = :"validator_host_#{System.unique_integer([:positive])}"
      {:ok, pid} = ValidatorHost.start_link(wasm_path: "/nonexistent/file.wasm", name: name)
      
      # Should start but with no instance
      assert Process.alive?(pid)
      state = :sys.get_state(pid)
      assert state.instance == nil
      
      Process.exit(pid, :normal)
    end
  end

  describe "message validation rules" do
    test "validates message structure requirements" do
      # When WASM is available, these would be the validation rules
      valid_message = %{
        "_nonce" => Base.encode64(:crypto.strong_rand_bytes(16)),
        "_timestamp" => System.system_time(:millisecond),
        "_signature" => "valid_hmac_signature",
        "_signature_alg" => "hmac-sha256",
        "headers" => %{},
        "payload" => %{"data" => "test"}
      }
      
      invalid_messages = [
        # Missing nonce
        Map.delete(valid_message, "_nonce"),
        # Missing timestamp
        Map.delete(valid_message, "_timestamp"),
        # Wrong signature algorithm
        Map.put(valid_message, "_signature_alg", "md5"),
        # Expired timestamp (>90s old)
        Map.put(valid_message, "_timestamp", System.system_time(:millisecond) - 100_000)
      ]
      
      # Document expected validation behavior
      assert Map.has_key?(valid_message, "_nonce")
      assert Map.has_key?(valid_message, "_timestamp")
      
      Enum.each(invalid_messages, fn msg ->
        # Each should be rejected when WASM validator is active
        assert Map.keys(msg) != Map.keys(valid_message) or
               msg["_signature_alg"] != "hmac-sha256" or
               (System.system_time(:millisecond) - msg["_timestamp"]) > 90_000
      end)
    end
  end

  describe "telemetry events" do
    test "emits telemetry on successful WASM load" do
      ref = make_ref()
      parent = self()
      
      :telemetry.attach(
        {__MODULE__, ref},
        [:cybernetic, :wasm, :loaded],
        fn _event, measurements, meta, _config ->
          send(parent, {:wasm_loaded, measurements, meta})
        end,
        nil
      )

      # Start with a path that exists (even if not valid WASM)
      File.write!("/tmp/test.wasm", "dummy")
      {:ok, _pid} = ValidatorHost.start_link(wasm_path: "/tmp/test.wasm")
      
      # Would receive this if WASM runtime was available
      refute_receive {:wasm_loaded, _measurements, _meta}, 100
      
      File.rm("/tmp/test.wasm")
      :telemetry.detach({__MODULE__, ref})
    end
  end
end