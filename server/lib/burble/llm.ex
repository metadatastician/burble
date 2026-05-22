# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

defmodule Burble.LLM do
  @moduledoc """
  Core LLM processing service for Burble.
  """

  require Logger

  # The provider module to delegate queries to. Set via configure_provider/1.
  # When nil, all queries return {:error, :no_provider_configured}.
  @provider nil

  @doc """
  Set the LLM provider module at runtime.
  The module must implement process_query/2 and stream_query/3.
  """
  def configure_provider(module) do
    :persistent_term.put({__MODULE__, :provider}, module)
    :ok
  end

  @pool_timeout 65_000

  @doc """
  Process a synchronous LLM query. Routes through the NimblePool to gate
  concurrency — at most `pool_size` (default 10) requests run simultaneously.
  """
  def process_query(user_id, prompt) do
    Logger.debug("[LLM] Processing query for #{user_id}")
    provider = :persistent_term.get({__MODULE__, :provider}, @provider)

    if provider do
      checkout_and_run(fn -> provider.process_query(user_id, prompt) end)
    else
      Logger.warning("[LLM] process_query called but no provider is configured")
      {:error, :no_provider_configured}
    end
  end

  @doc """
  Stream an LLM query response. Routes through the NimblePool to gate
  concurrency — the pool slot is held for the duration of the stream.
  """
  def stream_query(user_id, prompt, callback) do
    Logger.debug("[LLM] Streaming query for #{user_id}")
    provider = :persistent_term.get({__MODULE__, :provider}, @provider)

    if provider do
      checkout_and_run(fn -> provider.stream_query(user_id, prompt, callback) end)
    else
      Logger.warning("[LLM] stream_query called but no provider is configured")
      {:error, :no_provider_configured}
    end
  end

  # Checkout a worker from the pool, run the function, then check back in.
  # If the pool is exhausted, the caller blocks until a slot opens or timeout.
  defp checkout_and_run(fun) do
    try do
      NimblePool.checkout!(:llm_worker_pool, :checkout, fn _from, worker_state ->
        result = fun.()
        {result, worker_state}
      end, @pool_timeout)
    catch
      :exit, {:timeout, _} ->
        Logger.warning("[LLM] Pool checkout timeout — all workers busy")
        {:error, :pool_exhausted}

      :exit, reason ->
        Logger.error("[LLM] Pool checkout failed: #{inspect(reason)}")
        {:error, :pool_error}
    end
  end
end

defmodule Burble.LLM.Registry do
  @moduledoc """
  Registry for LLM connections.
  """

  def register_connection(user_id, pid) do
    :persistent_term.put({__MODULE__, user_id}, pid)
    :ok
  end

  def lookup_connection(user_id) do
    case :persistent_term.get({__MODULE__, user_id}, nil) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end
end
