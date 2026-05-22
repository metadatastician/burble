# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# BurbleWeb.Plugs.RateLimiter — ETS-backed token bucket rate limiter.
#
# Provides per-IP rate limiting for authentication endpoints to prevent
# brute-force attacks, credential stuffing, and abuse. Uses a token bucket
# algorithm stored in ETS for zero-GC overhead and sub-microsecond lookups.
#
# Token bucket algorithm:
#   - Each IP address gets a bucket with a configured capacity (max tokens)
#   - Tokens refill at a constant rate (tokens per second)
#   - Each request consumes one token
#   - When the bucket is empty, the request is rejected with 429
#   - The Retry-After header tells clients when to try again
#
# Configuration tiers (per-minute rates mapped to token bucket params):
#   - :login    → 10 req/min (login, register, magic-link)
#   - :refresh  → 30 req/min (token refresh)
#   - :guest    → 60 req/min (guest token issuance)
#
# ETS table layout:
#   Key: {ip_address, tier}
#   Value: {token_count :: float, last_refill_time :: integer}
#
# Author: Jonathan D.A. Jewell

defmodule BurbleWeb.Plugs.RateLimiter do
  @moduledoc """
  Plug that rate-limits requests using an ETS-backed token bucket.

  Designed for authentication endpoints where brute-force protection is
  critical. Each unique client IP gets an independent token bucket per
  rate-limit tier.

  ## Usage in a Phoenix router

      pipeline :api do
        plug :accepts, ["json"]
        plug BurbleWeb.Plugs.RateLimiter
      end

  The plug inspects the request path to determine which tier applies.
  Requests to paths not matching any tier pass through unrestricted.

  ## Extracting the real client IP

  In production behind a reverse proxy (Caddy, nginx, Cloudflare), the
  real client IP is in the `x-forwarded-for` or `x-real-ip` header.
  This plug checks those headers first, falling back to `conn.remote_ip`.
  """

  @behaviour Plug

  require Logger

  # ── Rate limit tiers ──
  #
  # Each tier is defined as {max_tokens, refill_rate_per_second}.
  # max_tokens = burst capacity (equal to per-minute limit for simplicity).
  # refill_rate = max_tokens / 60.0 (tokens per second).

  @tiers %{
    # 5 requests/minute: room creation to prevent spam.
    room_creation: {5, 5 / 60.0},
    # 10 requests/minute: login, register, magic-link endpoints.
    login: {10, 10 / 60.0},
    # 30 requests/minute: token refresh endpoint.
    refresh: {30, 30 / 60.0},
    # 60 requests/minute: guest token issuance.
    guest: {60, 60 / 60.0}
  }

  # Name of the ETS table used for bucket storage.
  @ets_table :burble_rate_limiter

  # Paths mapped to their rate-limit tiers. Matches are prefix-based
  # against the request path. Order matters: more specific paths first.
  # Format: {prefix, method_filter, tier}
  @path_tiers [
    {"/api/v1/rooms", "POST", :room_creation},
    {"/api/v1/auth/refresh", "POST", :refresh},
    {"/api/v1/auth/guest", "POST", :guest},
    {"/api/v1/auth/login", "POST", :login},
    {"/api/v1/auth/register", "POST", :login},
    {"/api/v1/auth/magic-link", "POST", :login}
  ]

  # ── Plug callbacks ──

  @doc """
  Initialise the rate limiter plug.

  Creates the ETS table if it does not already exist. The table uses
  `:public` access so that concurrent Cowboy acceptors can read/write
  without serialisation through a single process (ETS handles
  concurrent writes safely for simple key-value patterns).

  Options:
    - `:tiers` — override default tier configuration (map of tier_name => {max, rate})
    - `:enabled` — set to false to disable rate limiting (useful in tests)
  """
  @impl true
  def init(opts) do
    # Ensure the ETS table exists. :named_table + :public + :set.
    # If the table already exists (e.g. from a previous plug init or
    # test setup), we catch the ArgumentError and continue.
    try do
      :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])
      Logger.info("[RateLimiter] ETS table created: #{@ets_table}")
    rescue
      ArgumentError ->
        # Table already exists — this is normal during hot code reload
        # or when multiple routers reference this plug.
        :ok
    end

    %{
      tiers: Keyword.get(opts, :tiers, @tiers),
      enabled: Keyword.get(opts, :enabled, true)
    }
  end

  @doc """
  Execute the rate limiter for an incoming request.

  Steps:
    1. Determine the rate-limit tier from the request path
    2. Extract the client IP address
    3. Check/update the token bucket in ETS
    4. Allow the request (pass through) or reject with 429
  """
  @impl true
  def call(conn, %{enabled: false}), do: conn

  def call(conn, config) do
    case determine_tier(conn.request_path, conn.method) do
      nil ->
        # Path does not match any rate-limited tier — pass through.
        conn

      tier_name ->
        client_ip = extract_client_ip(conn)
        tiers = config.tiers

        case check_rate(client_ip, tier_name, tiers) do
          :ok ->
            conn

          {:rate_limited, retry_after_seconds} ->
            reject_request(conn, retry_after_seconds)
        end
    end
  end

  # ── Public API (for testing and administrative use) ──

  @doc """
  Reset the rate limiter state for a specific IP and tier.

  Useful in tests or when an admin wants to unblock a legitimate user.
  """
  @spec reset(String.t(), atom()) :: :ok
  def reset(ip, tier) do
    :ets.delete(@ets_table, {ip, tier})
    :ok
  end

  @doc """
  Reset all rate limiter state.

  Clears the entire ETS table. Use sparingly — this unblocks all IPs.
  """
  @spec reset_all() :: :ok
  def reset_all do
    try do
      :ets.delete_all_objects(@ets_table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc """
  Inspect the current bucket state for an IP and tier.

  Returns `{:ok, {tokens_remaining, last_refill_time}}` or `:not_found`.
  """
  @spec inspect_bucket(String.t(), atom()) :: {:ok, {float(), integer()}} | :not_found
  def inspect_bucket(ip, tier) do
    case :ets.lookup(@ets_table, {ip, tier}) do
      [{_key, tokens, last_refill}] -> {:ok, {tokens, last_refill}}
      [] -> :not_found
    end
  end

  # ── Private: Tier determination ──

  # Match the request path against configured rate-limit tiers.
  # Returns the tier atom or nil if the path is not rate-limited.
  @spec determine_tier(String.t(), String.t()) :: atom() | nil
  defp determine_tier(path, method) do
    Enum.find_value(@path_tiers, fn {prefix, required_method, tier} ->
      if String.starts_with?(path, prefix) and method == required_method do
        tier
      end
    end)
  end

  # ── Private: Client IP extraction ──

  # Extract the real client IP, checking proxy headers first.
  # Priority: x-real-ip > x-forwarded-for (first entry) > conn.remote_ip.
  #
  # Security note: These headers are trivially spoofable. In production,
  # the reverse proxy MUST strip/overwrite them before forwarding.
  @spec extract_client_ip(Plug.Conn.t()) :: String.t()
  defp extract_client_ip(conn) do
    cond do
      # x-real-ip: set by nginx/Caddy to the actual client IP.
      real_ip = get_header(conn, "x-real-ip") ->
        real_ip

      # x-forwarded-for: comma-separated list, first entry is the client.
      forwarded = get_header(conn, "x-forwarded-for") ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      # Fallback: use the connection's remote_ip tuple.
      true ->
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  # Get the first value for a request header (case-insensitive in HTTP/1.1,
  # but Plug lowercases all header names).
  @spec get_header(Plug.Conn.t(), String.t()) :: String.t() | nil
  defp get_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  # ── Private: Token bucket algorithm ──

  # Check whether the request is allowed under the token bucket algorithm.
  #
  # Algorithm:
  #   1. Look up the bucket for {ip, tier} in ETS
  #   2. If no bucket exists, create one with max tokens
  #   3. Refill tokens based on elapsed time since last check
  #   4. If tokens >= 1, consume one and allow the request
  #   5. If tokens < 1, reject and calculate Retry-After
  #
  # Returns :ok or {:rate_limited, retry_after_seconds}.
  @spec check_rate(String.t(), atom(), map()) :: :ok | {:rate_limited, non_neg_integer()}
  defp check_rate(ip, tier_name, tiers) do
    {max_tokens, refill_rate} = Map.fetch!(tiers, tier_name)
    now = System.monotonic_time(:millisecond)
    key = {ip, tier_name}

    # Atomic read-modify-write. ETS :set tables guarantee that a single
    # key update is atomic, but read-then-write is not. For rate limiting,
    # a small race condition is acceptable (worst case: a few extra requests
    # slip through under extreme concurrency). For stricter guarantees,
    # use :ets.update_counter/3 or a serialising GenServer.
    {tokens, _last_refill} =
      case :ets.lookup(@ets_table, key) do
        [{^key, stored_tokens, last_refill}] ->
          # Calculate tokens to add based on elapsed time.
          elapsed_ms = max(now - last_refill, 0)
          elapsed_seconds = elapsed_ms / 1000.0
          refilled = stored_tokens + elapsed_seconds * refill_rate

          # Cap at max_tokens (bucket cannot overflow).
          {min(refilled, max_tokens * 1.0), last_refill}

        [] ->
          # First request from this IP for this tier — full bucket.
          {max_tokens * 1.0, now}
      end

    if tokens >= 1.0 do
      # Consume one token and update the bucket.
      :ets.insert(@ets_table, {key, tokens - 1.0, now})
      :ok
    else
      # Bucket empty. Calculate how long until one token refills.
      # tokens_needed = 1.0 - tokens (could be negative if tokens < 0 due to float drift).
      tokens_needed = 1.0 - tokens
      retry_after_seconds = ceil(tokens_needed / refill_rate)

      # Update the timestamp so the next check correctly calculates refill.
      :ets.insert(@ets_table, {key, tokens, now})

      Logger.warning(
        "[RateLimiter] Rate limited #{ip} on :#{tier_name} — retry after #{retry_after_seconds}s"
      )

      {:rate_limited, retry_after_seconds}
    end
  end

  # ── Private: Response helpers ──

  # Send a 429 Too Many Requests response with the Retry-After header.
  # Halts the connection so no downstream plugs or controllers execute.
  @spec reject_request(Plug.Conn.t(), non_neg_integer()) :: Plug.Conn.t()
  defp reject_request(conn, retry_after_seconds) do
    body =
      Jason.encode!(%{
        error: "too_many_requests",
        message: "Rate limit exceeded. Please wait before retrying.",
        retry_after: retry_after_seconds
      })

    conn
    |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(429, body)
    |> Plug.Conn.halt()
  end
end
