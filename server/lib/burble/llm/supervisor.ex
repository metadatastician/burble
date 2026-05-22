# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

defmodule Burble.LLM.Supervisor do
  @moduledoc """
  LLM service supervisor.

  Manages the LLM transport listeners and worker pools.
  Configures the Anthropic provider at startup when ANTHROPIC_API_KEY is set.
  """

  use Supervisor
  require Logger

  @transport_workers 10

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    configure_provider()

    children = [
      {Burble.LLM.Transport, opts},

      {NimblePool, [
        worker: {Burble.LLM.Worker, []},
        pool_size: @transport_workers,
        name: :llm_worker_pool
      ]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp configure_provider do
    if System.get_env("ANTHROPIC_API_KEY") do
      Burble.LLM.configure_provider(Burble.LLM.AnthropicProvider)
      Logger.info("[LLM] Anthropic provider configured (model: #{System.get_env("ANTHROPIC_MODEL") || "claude-sonnet-4-6"})")
    else
      Logger.warning("[LLM] ANTHROPIC_API_KEY not set — LLM queries will return {:error, :no_provider_configured}")
    end
  end

  @doc """
  Get available transport.
  """
  def get_transport do
    case Supervisor.which_children(__MODULE__) do
      children when is_list(children) ->
        Enum.find_value(children, {:error, :transport_not_running}, fn
          {Burble.LLM.Transport, pid, :worker, _modules} when is_pid(pid) ->
            {:ok, pid}
          _ -> nil
        end)
      _ ->
        {:error, :transport_not_running}
    end
  end
end
