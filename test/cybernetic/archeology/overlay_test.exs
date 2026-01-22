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
            "function" => "unused_func",
            "arity" => 0,
            "file" => "lib/test.ex",
            "line" => 15,
            "type" => "public"
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
      assert MapSet.member?(result, {"Elixir.TestModule", "unused_func", 0})
      # Unknown type functions should be filtered out
      refute MapSet.member?(result, {"Elixir.TestModule", ".", 2})
    end

    test "handles empty traces" do
      empty_data = %{"traces" => [], "orphan_functions" => []}
      result = Overlay.normalize_static_functions(empty_data)

      assert MapSet.size(result) == 0
    end

    test "filters out unknown type functions" do
      result = Overlay.normalize_static_functions(@static_data)

      # Should only include public and private functions, not unknown
      assert MapSet.size(result) == 2
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

  describe "detect_dead_code/2" do
    test "computes static minus dynamic set difference" do
      # unused_func/0 is in static but not in dynamic
      dead_code = Overlay.detect_dead_code(@static_data, @dynamic_data)

      assert length(dead_code) == 1
      assert dead_code |> Enum.any?(fn fn_ref ->
        fn_ref["module"] == "Elixir.TestModule" and fn_ref["function"] == "unused_func"
      end)
    end

    test "filters out test functions" do
      static_with_test = %{
        "traces" => [
          %{
            "functions" => [
              %{
                "module" => "Elixir.TestModule",
                "function" => "test_func",
                "arity" => 1,
                "file" => "lib/test.ex",
                "line" => 10,
                "type" => "public"
              },
              %{
                "module" => "Elixir.TestModuleTest",
                "function" => "regular_func",
                "arity" => 0,
                "file" => "test/test.ex",
                "line" => 5,
                "type" => "public"
              }
            ]
          }
        ],
        "orphan_functions" => []
      }

      dead_code = Overlay.detect_dead_code(static_with_test, @dynamic_data)

      # Both test functions should be filtered out
      refute Enum.any?(dead_code, fn fn_ref -> fn_ref["function"] == "test_func" end)
      refute Enum.any?(dead_code, fn fn_ref -> String.contains?(fn_ref["module"], "Test") end)
    end

    test "filters out callback functions" do
      static_with_callbacks = %{
        "traces" => [
          %{
            "functions" => [
              %{
                "module" => "Elixir.MyGenServer",
                "function" => "init",
                "arity" => 1,
                "file" => "lib/server.ex",
                "line" => 10,
                "type" => "public"
              },
              %{
                "module" => "Elixir.MyGenServer",
                "function" => "handle_info",
                "arity" => 2,
                "file" => "lib/server.ex",
                "line" => 15,
                "type" => "public"
              }
            ]
          }
        ],
        "orphan_functions" => []
      }

      dead_code = Overlay.detect_dead_code(static_with_callbacks, @dynamic_data)

      # Callback functions should be filtered out
      refute Enum.any?(dead_code, fn fn_ref -> fn_ref["function"] == "init" end)
      refute Enum.any?(dead_code, fn fn_ref -> fn_ref["function"] == "handle_info" end)
    end

    test "sorts results by module, function, arity" do
      dead_code = Overlay.detect_dead_code(@static_data, @dynamic_data)

      # Should be sorted
      assert length(dead_code) > 0

      # Check sorting
      modules = Enum.map(dead_code, & &1["module"])
      assert modules == Enum.sort(modules)
    end
  end

  describe "is_test_function?/1" do
    test "identifies test functions by module name" do
      test_fn = %{
        "module" => "Elixir.MyAppTest",
        "function" => "regular_func",
        "arity" => 0
      }

      assert Overlay.is_test_function?(test_fn)
    end

    test "identifies test functions by function name" do
      test_fn = %{
        "module" => "Elixir.MyApp",
        "function" => "test_something",
        "arity" => 1
      }

      assert Overlay.is_test_function?(test_fn)
    end

    test "returns false for non-test functions" do
      regular_fn = %{
        "module" => "Elixir.MyApp",
        "function" => "regular_func",
        "arity" => 0
      }

      refute Overlay.is_test_function?(regular_fn)
    end
  end

  describe "is_callback_function?/1" do
    test "identifies GenServer callbacks" do
      callbacks = [
        %{"function" => "init", "arity" => 1},
        %{"function" => "handle_call", "arity" => 3},
        %{"function" => "handle_cast", "arity" => 2},
        %{"function" => "handle_info", "arity" => 2},
        %{"function" => "terminate", "arity" => 2},
        %{"function" => "code_change", "arity" => 3}
      ]

      for callback <- callbacks do
        assert Overlay.is_callback_function?(callback)
      end
    end

    test "returns false for non-callback functions" do
      regular_fn = %{
        "function" => "regular_func",
        "arity" => 0
      }

      refute Overlay.is_callback_function?(regular_fn)
    end
  end

  describe "detect_ghost_paths/2" do
    test "computes dynamic minus static set difference" do
      # DynamicModule.dynamic_func/2 is in dynamic but not in static
      ghost_paths = Overlay.detect_ghost_paths(@static_data, @dynamic_data)

      assert length(ghost_paths) == 1
      assert ghost_paths |> Enum.any?(fn ghost ->
        ghost["module"] == "Elixir.DynamicModule" and ghost["function"] == "dynamic_func"
      end)
    end

    test "tracks execution count" do
      # Add another execution of the same ghost function
      dynamic_with_multiple = %{
        "traces" => [
          %{
            "trace_id" => "test123",
            "spans" => [
              %{
                "module" => "Elixir.DynamicModule",
                "function" => "dynamic_func",
                "arity" => 2,
                "file" => "lib/dynamic.ex",
                "line" => 5,
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

      ghost_paths = Overlay.detect_ghost_paths(@static_data, dynamic_with_multiple)

      assert length(ghost_paths) == 1
      ghost = List.first(ghost_paths)
      assert ghost["execution_count"] == 2
    end

    test "sorts by module, function, arity" do
      ghost_paths = Overlay.detect_ghost_paths(@static_data, @dynamic_data)

      # Should be sorted
      assert length(ghost_paths) > 0

      # Check sorting
      modules = Enum.map(ghost_paths, & &1["module"])
      assert modules == Enum.sort(modules)
    end

    test "returns empty list when all dynamic functions are in static" do
      # Dynamic data with no ghost paths
      dynamic_no_ghosts = %{
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
              }
            ]
          }
        ]
      }

      ghost_paths = Overlay.detect_ghost_paths(@static_data, dynamic_no_ghosts)

      assert length(ghost_paths) == 0
    end
  end
end
