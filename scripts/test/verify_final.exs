#!/usr/bin/env elixir

# Final verification - ALL services 100% operational
Mix.install([
  {:httpoison, "~> 2.0"},
  {:jason, "~> 1.4"}
])

defmodule FinalVerification do
  @services [
    {"RabbitMQ Management", "http://localhost:15672/api/overview", 
     [{"Authorization", "Basic " <> Base.encode64("cybernetic:" <> (System.get_env("RABBITMQ_PASSWORD") || ""))}]},
    {"Jaeger UI", "http://localhost:16686/api/services", []},
    {"Prometheus", "http://localhost:9090/api/v1/targets", []},
    {"Grafana", "http://localhost:3000/api/health", 
     [{"Authorization", "Basic " <> Base.encode64("admin:changeme")}]},
    {"Ollama", "http://localhost:11434/api/tags", []}
  ]
  
  def run do
    IO.puts("\n🚀 FINAL SYSTEM VERIFICATION - 100% OPERATIONAL CHECK\n")
    IO.puts(String.duplicate("=", 70))
    
    # Check Docker containers
    verify_containers()
    
    # Check all HTTP services
    results = verify_services()
    
    # Check specific service details
    verify_service_details()
    
    # Final summary
    print_summary(results)
  end
  
  defp verify_containers do
    IO.puts("\n📦 Docker Containers Status:")
    {output, _} = System.cmd("docker", ["ps", "--format", "table {{.Names}}\t{{.Status}}\t{{.Ports}}"])
    
    containers = [
      "cyb-rabbitmq",
      "cyb-postgres", 
      "cyb-redis",
      "cyb-jaeger",
      "cyb-prometheus",
      "cyb-grafana",
      "cyb-ollama",
      "cyb-otel"
    ]
    
    Enum.each(containers, fn name ->
      status = if String.contains?(output, name), do: "✅ RUNNING", else: "❌ NOT RUNNING"
      IO.puts("   #{status} - #{name}")
    end)
  end
  
  defp verify_services do
    IO.puts("\n🌐 Service Endpoints:")
    
    Enum.map(@services, fn {name, url, headers} ->
      case HTTPoison.get(url, headers, recv_timeout: 5000) do
        {:ok, %{status_code: code}} when code in 200..299 ->
          IO.puts("   ✅ #{name}: ONLINE (#{code})")
          {name, :ok}
        {:ok, %{status_code: code}} ->
          IO.puts("   ⚠️  #{name}: Response code #{code}")
          {name, :warning}
        {:error, reason} ->
          IO.puts("   ❌ #{name}: #{inspect(reason)}")
          {name, :error}
      end
    end)
  end
  
  defp verify_service_details do
    IO.puts("\n📊 Service Details:")
    
    # Jaeger traces
    case HTTPoison.get("http://localhost:16686/api/services") do
      {:ok, %{status_code: 200, body: body}} ->
        services = Jason.decode!(body)["data"] || []
        IO.puts("\n   🔍 Jaeger:")
        IO.puts("      Services: #{Enum.join(services, ", ")}")
        
        if "cybernetic" in services do
          case HTTPoison.get("http://localhost:16686/api/traces?service=cybernetic&limit=100") do
            {:ok, %{status_code: 200, body: trace_body}} ->
              traces = Jason.decode!(trace_body)["data"] || []
              IO.puts("      Cybernetic traces: #{length(traces)}")
            _ -> :ok
          end
        end
      _ -> :ok
    end
    
    # Prometheus metrics
    case HTTPoison.get("http://localhost:9090/api/v1/targets") do
      {:ok, %{status_code: 200, body: body}} ->
        data = Jason.decode!(body)
        active = data["data"]["activeTargets"] || []
        IO.puts("\n   📈 Prometheus:")
        IO.puts("      Active targets: #{length(active)}")
        
        Enum.each(active, fn target ->
          job = target["labels"]["job"]
          health = target["health"]
          IO.puts("      - #{job}: #{health}")
        end)
      _ -> :ok
    end
    
    # Grafana dashboards
    auth = Base.encode64("admin:changeme")
    case HTTPoison.get("http://localhost:3000/api/datasources", [{"Authorization", "Basic #{auth}"}]) do
      {:ok, %{status_code: 200, body: body}} ->
        datasources = Jason.decode!(body)
        IO.puts("\n   📊 Grafana:")
        IO.puts("      Datasources: #{length(datasources)}")
        
        Enum.each(datasources, fn ds ->
          IO.puts("      - #{ds["name"]}: #{ds["type"]}")
        end)
      _ -> :ok
    end
    
    # Ollama models
    case HTTPoison.get("http://localhost:11434/api/tags") do
      {:ok, %{status_code: 200, body: body}} ->
        data = Jason.decode!(body)
        models = data["models"] || []
        IO.puts("\n   🤖 Ollama:")
        
        if length(models) > 0 do
          IO.puts("      Models: #{length(models)}")
          Enum.each(Enum.take(models, 3), fn model ->
            IO.puts("      - #{model["name"]}")
          end)
        else
          IO.puts("      ⚠️  No models installed")
          IO.puts("      Run: ollama pull llama2")
        end
      _ -> :ok
    end
    
    # Check OTEL collector
    {logs, _} = System.cmd("docker", ["logs", "--tail", "5", "cyb-otel"], stderr_to_stdout: true)
    IO.puts("\n   📡 OTEL Collector:")
    if String.contains?(logs, "Everything is ready") do
      IO.puts("      ✅ Pipelines active")
      IO.puts("      Exporting traces to Jaeger")
      IO.puts("      Exporting metrics to Prometheus")
    else
      IO.puts("      ⚠️  Check logs for status")
    end
  end
  
  defp print_summary(results) do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("📋 FINAL SUMMARY:\n")
    
    ok_count = Enum.count(results, fn {_, status} -> status == :ok end)
    warning_count = Enum.count(results, fn {_, status} -> status == :warning end)
    error_count = Enum.count(results, fn {_, status} -> status == :error end)
    
    IO.puts("   ✅ Operational: #{ok_count}/#{length(results)}")
    IO.puts("   ⚠️  Warnings: #{warning_count}")
    IO.puts("   ❌ Errors: #{error_count}")
    
    IO.puts("\n📌 Quick Access URLs:")
    IO.puts("   • RabbitMQ: http://localhost:15672 (user cybernetic, password from RABBITMQ_PASSWORD)")
    IO.puts("   • Jaeger: http://localhost:16686")
    IO.puts("   • Prometheus: http://localhost:9090")
    IO.puts("   • Grafana: http://localhost:3000 (admin/changeme)")
    
    if ok_count == length(results) do
      IO.puts("\n🎉 ALL SERVICES ARE 100% OPERATIONAL! 🎉")
    else
      failed = Enum.filter(results, fn {_, status} -> status != :ok end)
      |> Enum.map(fn {name, _} -> name end)
      IO.puts("\n⚠️  Services needing attention: #{Enum.join(failed, ", ")}")
    end
    
    IO.puts(String.duplicate("=", 70) <> "\n")
  end
end

FinalVerification.run()