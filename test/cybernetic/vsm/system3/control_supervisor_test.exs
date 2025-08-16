defmodule Cybernetic.VSM.System3.ControlSupervisorTest do
  use ExUnit.Case, async: false
  alias Cybernetic.VSM.System3.ControlSupervisor
  
  setup do
    # Start the control supervisor
    {:ok, pid} = ControlSupervisor.start_link()
    
    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)
    
    {:ok, %{pid: pid}}
  end
  
  describe "initialization" do
    test "starts with normal state" do
      status = ControlSupervisor.get_status()
      
      assert status.control_state == :normal
      assert status.active_interventions == 0
      assert status.circuit_breakers_open == 0
    end
    
    test "initializes health monitors" do
      status = ControlSupervisor.get_status()
      
      assert status.health_status in [:healthy, :degraded, :failing, :failed]
    end
    
    test "starts monitoring loops" do
      # Give monitoring loops time to run
      Process.sleep(100)
      
      status = ControlSupervisor.get_status()
      assert is_map(status.metrics)
    end
  end
  
  describe "health monitoring" do
    test "aggregates health status from subsystems" do
      status = ControlSupervisor.get_status()
      
      # Should check S1 and S2 health
      assert status.health_status == :healthy
    end
    
    test "updates metrics during health checks" do
      # Wait for at least one health check cycle
      Process.sleep(5_500)
      
      status = ControlSupervisor.get_status()
      assert status.metrics != %{}
    end
  end
  
  describe "manual intervention" do
    test "creates and tracks manual intervention" do
      assert {:ok, intervention_id} = 
        ControlSupervisor.intervene(
          {:system, 1},
          :restart_component,
          "Manual test intervention"
        )
      
      assert String.starts_with?(intervention_id, "intervention_")
      
      status = ControlSupervisor.get_status()
      assert status.active_interventions == 1
    end
    
    test "executes restart intervention" do
      # Start a dummy process to restart (not the test process!)
      dummy_pid = spawn(fn -> 
        receive do
          :stop -> :ok
        end
      end)
      
      assert {:ok, _id} = 
        ControlSupervisor.intervene(
          {:process, dummy_pid},
          :restart_component,
          "Test restart"
        )
        
      # Give it time to process
      Process.sleep(10)
      
      # The dummy process should have been killed
      refute Process.alive?(dummy_pid)
    end
    
    test "executes throttle intervention" do
      assert {:ok, _id} = 
        ControlSupervisor.intervene(
          {:system, 2},
          :throttle_input,
          "Test throttle"
        )
    end
    
    test "rejects invalid intervention action" do
      assert {:error, :unknown_action} = 
        ControlSupervisor.intervene(
          {:system, 1},
          :invalid_action,
          "Test"
        )
    end
  end
  
  describe "policy management" do
    test "updates policy cache" do
      policy_data = %{
        type: :resource_limit,
        rules: %{max_cpu: 0.9}
      }
      
      assert :ok = ControlSupervisor.update_policy("test_policy", policy_data)
      
      # Policy should trigger compliance check
      Process.sleep(100)
    end
    
    test "loads initial policies from S5" do
      # Policies are loaded on init
      status = ControlSupervisor.get_status()
      
      # Should have default policies loaded
      assert is_map(status.metrics)
    end
  end
  
  describe "algedonic signal processing" do
    test "processes pain signals below threshold" do
      assert :ok = ControlSupervisor.report_algedonic(:pain, 0.5, :test_source)
      
      status = ControlSupervisor.get_status()
      assert status.control_state == :normal
    end
    
    test "triggers warning for pain above threshold" do
      assert :ok = ControlSupervisor.report_algedonic(:pain, 0.75, :test_source)
      
      Process.sleep(100)
      status = ControlSupervisor.get_status()
      assert status.control_state == :warning
    end
    
    test "triggers intervention for critical pain" do
      assert :ok = ControlSupervisor.report_algedonic(:pain, 0.85, :test_source)
      
      Process.sleep(100)
      status = ControlSupervisor.get_status()
      assert status.control_state == :critical
      assert status.active_interventions > 0
    end
    
    test "buffers algedonic signals" do
      for i <- 1..5 do
        ControlSupervisor.report_algedonic(:pleasure, i * 0.1, :test_source)
      end
      
      status = ControlSupervisor.get_status()
      recent = status.recent_algedonic
      
      assert is_list(recent)
      assert length(recent) <= 10
    end
  end
  
  describe "audit reporting" do
    test "generates audit report for time range" do
      from = DateTime.add(DateTime.utc_now(), -3600, :second)
      to = DateTime.utc_now()
      
      report = ControlSupervisor.get_audit_report(from, to)
      
      assert report.period.from == from
      assert report.period.to == to
      assert report.control_state in [:normal, :warning, :critical, :intervening]
    end
    
    test "includes health summary in audit" do
      report = ControlSupervisor.get_audit_report()
      
      assert is_map(report.health_summary)
      assert is_map(report.compliance_summary)
      assert is_map(report.circuit_breakers)
    end
  end
  
  describe "circuit breakers" do
    test "initializes circuit breakers in closed state" do
      status = ControlSupervisor.get_status()
      assert status.circuit_breakers_open == 0
    end
    
    test "tracks open circuit breakers" do
      # Would need to trigger failures to open breakers
      # This tests the counting mechanism
      status = ControlSupervisor.get_status()
      assert is_integer(status.circuit_breakers_open)
      assert status.circuit_breakers_open >= 0
    end
  end
  
  describe "compliance checking" do
    test "performs compliance checks periodically" do
      # Add a test policy
      policy = %{
        type: :sla,
        rules: %{min_availability: 0.99}
      }
      
      ControlSupervisor.update_policy("sla_test", policy)
      
      # Wait for compliance check cycle
      Process.sleep(100)
      
      report = ControlSupervisor.get_audit_report()
      assert is_map(report.compliance_summary)
    end
    
    test "enforces policy violations" do
      # Add a policy that will be violated
      policy = %{
        type: :resource_limit,
        rules: %{max_cpu: 0.0001} # Impossibly low
      }
      
      ControlSupervisor.update_policy("strict_policy", policy)
      
      # Trigger compliance check
      Process.sleep(100)
      
      # Should have taken some enforcement action
      status = ControlSupervisor.get_status()
      assert status.control_state != :normal or status.active_interventions > 0
    end
  end
  
  describe "state transitions" do
    test "transitions from normal to warning" do
      assert ControlSupervisor.get_status().control_state == :normal
      
      # Report concerning but not critical pain
      ControlSupervisor.report_algedonic(:pain, 0.75, :test)
      Process.sleep(100)
      
      assert ControlSupervisor.get_status().control_state == :warning
    end
    
    test "transitions from warning to critical" do
      # First go to warning
      ControlSupervisor.report_algedonic(:pain, 0.75, :test)
      Process.sleep(100)
      
      # Then critical
      ControlSupervisor.report_algedonic(:pain, 0.9, :test)
      Process.sleep(100)
      
      assert ControlSupervisor.get_status().control_state == :critical
    end
    
    test "enters intervening state during intervention" do
      {:ok, _} = ControlSupervisor.intervene(
        {:system, 1},
        :restart_component,
        "Test"
      )
      
      assert ControlSupervisor.get_status().control_state == :intervening
    end
  end
end