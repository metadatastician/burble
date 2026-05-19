# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Shared test helpers for Burble test suite.
#
# Provides audio generation utilities and common assertions used across
# multiple test modules. Compiled into the :test environment via
# elixirc_paths/1 in mix.exs.

defmodule Burble.TestHelpers do
  @moduledoc """
  Shared helper functions for Burble tests.

  Provides audio frame generation, RMS calculation, and common
  test data factories.
  """

  @frame_length 960
  @sample_rate 48_000

  @doc "Generate a sine wave audio frame at the given frequency and amplitude."
  @spec generate_tone(float(), float(), non_neg_integer()) :: [float()]
  def generate_tone(freq \\ 440.0, amplitude \\ 0.3, length \\ @frame_length) do
    for i <- 1..length do
      :math.sin(2.0 * :math.pi() * freq * i / @sample_rate) * amplitude
    end
  end

  @doc "Generate a sine wave with additive noise."
  @spec generate_noisy_tone(float(), float(), float()) :: [float()]
  def generate_noisy_tone(freq \\ 440.0, amplitude \\ 0.3, noise_level \\ 0.02) do
    for i <- 1..@frame_length do
      :math.sin(2.0 * :math.pi() * freq * i / @sample_rate) * amplitude +
        (:rand.uniform() - 0.5) * noise_level
    end
  end

  @doc "Calculate RMS (root mean square) of a sample list."
  @spec rms([float()]) :: float()
  def rms(samples) when is_list(samples) do
    sum_sq = Enum.reduce(samples, 0.0, fn s, acc -> acc + s * s end)
    :math.sqrt(sum_sq / max(length(samples), 1))
  end

  @doc "Generate a valid room ID (alphanumeric, safe characters only)."
  @spec generate_room_id() :: String.t()
  def generate_room_id do
    "test-room-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  @doc "Generate a valid user ID."
  @spec generate_user_id() :: String.t()
  def generate_user_id do
    "user-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  @doc """
  Start a child spec for the test, or reuse it if the application already
  owns it (shared-app+reset test strategy, burble#62). Returns `{:ok, pid}`
  whether freshly started or already running, so setups never crash on
  `:already_started` for app-owned singletons.
  """
  @spec ensure_started(tuple() | module()) :: {:ok, pid()}
  def ensure_started(spec) do
    case ExUnit.Callbacks.start_supervised(spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {{:already_started, pid}, _spec}} -> {:ok, pid}
      {:error, reason} -> raise "ensure_started failed: #{inspect(reason)}"
    end
  end

  @doc "Build a Plug.Conn for testing API endpoints."
  @spec build_conn(String.t(), String.t(), map()) :: Plug.Conn.t()
  def build_conn(method, path, params \\ %{}) do
    Plug.Test.conn(method, path, Jason.encode!(params))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("accept", "application/json")
  end
end
