# Set test mode to prevent feedback loops
Application.put_env(:cybernetic, :test_mode, true)

ExUnit.start()