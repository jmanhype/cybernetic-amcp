defmodule Cybernetic.Edge.Gateway.Router do
  @moduledoc """
  Phoenix Edge Gateway for handling API traffic with security, 
  performance, and multi-tenancy support.
  """
  use Phoenix.Router
  import Plug.Conn

  pipeline :api do
    plug(:accepts, ["json"])
    plug(Cybernetic.Edge.Gateway.Plugs.RequestId)
    plug(Cybernetic.Edge.Gateway.Plugs.OIDC)
    plug(Cybernetic.Edge.Gateway.Plugs.TenantIsolation)
    plug(Cybernetic.Edge.Gateway.Plugs.RateLimiter)
    plug(Cybernetic.Edge.Gateway.Plugs.CircuitBreaker)
  end

  pipeline :sse do
    plug(:accepts, ["text/event-stream"])
    plug(Cybernetic.Edge.Gateway.Plugs.RequestId)
    plug(Cybernetic.Edge.Gateway.Plugs.OIDC)
    plug(Cybernetic.Edge.Gateway.Plugs.TenantIsolation)
  end

  # API v1 endpoints
  scope "/v1", Cybernetic.Edge.Gateway do
    pipe_through(:api)

    post("/generate", GenerateController, :create)
  end

  # SSE endpoint
  scope "/v1", Cybernetic.Edge.Gateway do
    pipe_through(:sse)

    get("/events", EventsController, :stream)
  end

  # Telegram webhook (no auth required)
  scope "/telegram", Cybernetic.Edge.Gateway do
    post("/webhook", TelegramController, :webhook)
  end

  # Prometheus metrics endpoint (no auth)
  scope "/metrics", Cybernetic.Edge.Gateway do
    get("/", MetricsController, :index)
  end
end
