defmodule Ytd.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      YtdWeb.Telemetry,
      Ytd.Repo,
      {DNSCluster, query: Application.get_env(:ytd, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Ytd.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Ytd.Finch},
      # Start a worker by calling: Ytd.Worker.start_link(arg)
      # {Ytd.Worker, arg},
      Ytd.VideoProcessor,
      # Start to serve requests, typically the last entry
      YtdWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ytd.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    YtdWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
