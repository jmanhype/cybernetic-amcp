defmodule Cybernetic.Archeology.OverlayTest do
  use ExUnit.Case
  alias Cybernetic.Archeology.Overlay

  @static_data %{
    "traces" => [
      %{
        "functions" => [
          %{
            "module" => "Elixir.TestModule",
            "function" => "public_func",
            "arity" => 1,
            "file" => "lib/test.ex",
            "line" => 10,
            "type" => "public"
          },
          %{
            "module" => "Elixir.TestModule",
            "function" => "private_func",
            "arity" => 0,
            "file" => "lib/test.ex",
            "line" => 15,
            "type" => "private"
          },
          %{
            "module" => "Elixir.TestModule",
            "function" => ".",
            "arity" => 2,
            "file" => "lib/test.ex",
            "line" => 20,
            "type" => "unknown"
          }
        ]
      }
    ],
    "orphan_functions" => []
  }

  @dynamic_data %{
    "traces" => [
      %{
        "trace_id" => "test123",
        "spans" => [
          %{
            "module" => "Elixir.TestModule",
            "function" => "public_func",
            "arity" => 1,
            "file" => "lib/test.ex",
            "line" => 10,
            "timestamp" => 1234567890,
            "duration_us" => 100
          },
          %{
            "module" => "Elixir.DynamicModule",
            "function" => "dynamic_func",
            "arity" => 2,
            "file" => "lib/dynamic.ex",
            "line" => 5,
            "timestamp" => 1234567891,
            "duration_us" => 50
          }
        ]
      }
    ]
  }

  describe "load_static_data/1" do
    test "loads and parses archeology-results.json" do
      # Create a temporary file with test data
      path = System.tmp_dir!() |> Path.join("test_static.json")
      content = Jason.encode!(@static_data)
      File.write!(path, content)

      result = Overlay.load_static_data(path)

      assert is_map(result)
      assert Map.has_key?(result, "traces")
      assert Map.has_key?(result, "orphan_functions")
      assert length(result["traces"]) == 1

      File.rm!(path)
    end

    test "raises error for non-existent file" do
      assert_raise RuntimeError, ~r/Failed to read/, fn ->
        Overlay.load_static_data("/non/existent/path.json")
      end
    end
  end

  describe "load_dynamic_data/1" do
    test "loads and parses dynamic-traces.json" do
      path = System.tmp_dir!() |> Path.join("test_dynamic.json")
      content = Jason.encode!(@dynamic_data)
      File.write!(path, content)

      result = Overlay.load_dynamic_data(path)

      assert is_map(result)
      assert Map.has_key?(result, "traces")
      assert length(result["traces"]) == 1

      File.rm!(path)
    end

    test "raises error for non-existent file" do
      assert_raise RuntimeError, ~r/Failed to read/, fn ->
        Overlay.load_dynamic_data("/non/existent/path.json")
      end
    end
  end

  describe "normalize_static_functions/1" do
    test "converts static functions to normalized map set" do
      result = Overlay.normalize_static_functions(@static_data)

      assert MapSet.size(result) == 2
      assert MapSet.member?(result, {"Elixir.TestModule", "public_func", 1})
      assert MapSet.member?(result, {"Elixir.TestModule", "private_func", 0})
      # Unknown type functions should be filtered out
      refute MapSet.member?(result, {"Elixir.TestModule", ".", 2})
    end

    test "handles empty traces" do
      empty_data = %{"traces" => [], "orphan_functions" => []}
      result = Overlay.normalize_static_functions(empty_data)

      assert MapSet.size(result) == 0
    end
  end

  describe "normalize_dynamic_spans/1" do
    test "converts dynamic spans to normalized map set" do
      result = Overlay.normalize_dynamic_spans(@dynamic_data)

      assert MapSet.size(result) == 2
      assert MapSet.member?(result, {"Elixir.TestModule", "public_func", 1})
      assert MapSet.member?(result, {"Elixir.DynamicModule", "dynamic_func", 2})
    end

    test "handles empty traces" do
      empty_data = %{"traces" => []}
      result = Overlay.normalize_dynamic_spans(empty_data)

      assert MapSet.size(result) == 0
    end
  end

  describe "group_static_functions_by_module/1" do
    test "groups functions by module name" do
      result = Overlay.group_static_functions_by_module(@static_data)

      assert is_map(result)
      assert Map.has_key?(result, "Elixir.TestModule")
      assert length(result["Elixir.TestModule"]) == 2
    end
  end

  describe "group_dynamic_spans_by_module/1" do
    test "groups spans by module and counts executions" do
      result = Overlay.group_dynamic_spans_by_module(@dynamic_data)

      assert is_map(result)
      assert Map.has_key?(result, "Elixir.TestModule")
      assert Map.has_key?(result, "Elixir.DynamicModule")

      assert result["Elixir.TestModule"][{"Elixir.TestModule", "public_func", 1}] == 1
      assert result["Elixir.DynamicModule"][{"Elixir.DynamicModule", "dynamic_func", 2}] == 1
    end
  end
end
