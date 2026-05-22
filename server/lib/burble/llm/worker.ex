# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

defmodule Burble.LLM.Worker do
  @moduledoc """
  Worker for NimblePool in the LLM service.
  """

  @behaviour NimblePool

  @impl true
  def init_pool(state) do
    {:ok, state}
  end

  @impl true
  def init_worker(state) do
    # Intentionally minimal: no persistent connection is opened until a
    # provider module is configured via Burble.LLM.configure_provider/1.
    {:ok, %{}, state}
  end

  @impl true
  def handle_checkout(args, _from, worker_state, pool_state) do
    {:ok, args, worker_state, pool_state}
  end

  @impl true
  def handle_checkin(_args, _from, worker_state, pool_state) do
    {:ok, worker_state, pool_state}
  end

  @impl true
  def terminate_worker(_reason, _worker_state, pool_state) do
    {:ok, pool_state}
  end
end
