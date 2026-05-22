# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for BurbleWeb.Plugs.RateLimiter — ETS-backed token bucket.
#
# Verifies rate limiting tiers, IP extraction, bucket overflow,
# and the Retry-After header.

defmodule BurbleWeb.Plugs.RateLimiterTest do
  use ExUnit.Case, async: false

  alias BurbleWeb.Plugs.RateLimiter

  setup do
    # Ensure the ETS table exists (init creates it) and clean between tests.
    RateLimiter.init([])
    RateLimiter.reset_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tier determination
  # ---------------------------------------------------------------------------

  describe "rate limit tiers" do
    test "login path is rate limited" do
      config = RateLimiter.init([])

      conn =
        Plug.Test.conn(:post, "/api/v1/auth/login")
        |> Map.put(:remote_ip, {192, 168, 1, 1})

      # First 10 requests should pass (login tier = 10 req/min).
      for _ <- 1..10 do
        result = RateLimiter.call(conn, config)
        refute result.halted, "Request should be allowed within rate limit"
      end

      # The 11th request should be rate limited.
      result = RateLimiter.call(conn, config)
      assert result.halted, "Request should be rate limited after exhausting bucket"
      assert result.status == 429
    end

    test "non-auth paths pass through without rate limiting" do
      config = RateLimiter.init([])

      conn =
        Plug.Test.conn(:get, "/api/v1/rooms/some-room")
        |> Map.put(:remote_ip, {192, 168, 1, 1})

      # Should always pass — no tier matches this path.
      for _ <- 1..50 do
        result = RateLimiter.call(conn, config)
        refute result.halted, "Non-auth paths should not be rate limited"
      end
    end

    test "health endpoint is not rate limited" do
      config = RateLimiter.init([])

      conn =
        Plug.Test.conn(:get, "/api/v1/health")
        |> Map.put(:remote_ip, {192, 168, 1, 1})

      for _ <- 1..100 do
        result = RateLimiter.call(conn, config)
        refute result.halted
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Retry-After header
  # ---------------------------------------------------------------------------

  describe "429 response" do
    test "includes Retry-After header" do
      config = RateLimiter.init([])

      conn =
        Plug.Test.conn(:post, "/api/v1/auth/login")
        |> Map.put(:remote_ip, {10, 0, 0, 1})

      # Exhaust the bucket.
      for _ <- 1..10 do
        RateLimiter.call(conn, config)
      end

      # Next request should include Retry-After.
      result = RateLimiter.call(conn, config)
      assert result.status == 429

      retry_after = Plug.Conn.get_resp_header(result, "retry-after")
      assert length(retry_after) > 0, "Should include Retry-After header"

      {seconds, _} = Integer.parse(hd(retry_after))
      assert seconds > 0, "Retry-After should be positive"
    end

    test "returns JSON error body" do
      config = RateLimiter.init([])

      conn =
        Plug.Test.conn(:post, "/api/v1/auth/login")
        |> Map.put(:remote_ip, {10, 0, 0, 2})

      # Exhaust the bucket.
      for _ <- 1..10, do: RateLimiter.call(conn, config)
      result = RateLimiter.call(conn, config)

      body = Jason.decode!(result.resp_body)
      assert body["error"] == "too_many_requests"
      assert is_integer(body["retry_after"])
    end
  end

  # ---------------------------------------------------------------------------
  # IP extraction
  # ---------------------------------------------------------------------------

  describe "IP extraction" do
    test "different IPs have independent buckets" do
      config = RateLimiter.init([])

      conn_a =
        Plug.Test.conn(:post, "/api/v1/auth/login")
        |> Map.put(:remote_ip, {10, 0, 0, 10})

      conn_b =
        Plug.Test.conn(:post, "/api/v1/auth/login")
        |> Map.put(:remote_ip, {10, 0, 0, 11})

      # Exhaust bucket for IP A.
      for _ <- 1..10, do: RateLimiter.call(conn_a, config)
      result_a = RateLimiter.call(conn_a, config)
      assert result_a.halted, "IP A should be rate limited"

      # IP B should still have its full bucket.
      result_b = RateLimiter.call(conn_b, config)
      refute result_b.halted, "IP B should not be affected by IP A's rate limit"
    end
  end

  # ---------------------------------------------------------------------------
  # Disabled mode
  # ---------------------------------------------------------------------------

  describe "disabled mode" do
    test "passes all requests when disabled" do
      config = RateLimiter.init(enabled: false)

      conn =
        Plug.Test.conn(:post, "/api/v1/auth/login")
        |> Map.put(:remote_ip, {10, 0, 0, 20})

      for _ <- 1..100 do
        result = RateLimiter.call(conn, config)
        refute result.halted, "Should pass when rate limiter is disabled"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Reset
  # ---------------------------------------------------------------------------

  describe "reset/2" do
    test "clears bucket for specific IP and tier" do
      config = RateLimiter.init([])

      conn =
        Plug.Test.conn(:post, "/api/v1/auth/login")
        |> Map.put(:remote_ip, {10, 0, 0, 30})

      # Exhaust bucket.
      for _ <- 1..10, do: RateLimiter.call(conn, config)
      result = RateLimiter.call(conn, config)
      assert result.halted

      # Reset the bucket.
      RateLimiter.reset("10.0.0.30", :login)

      # Should be allowed again.
      result = RateLimiter.call(conn, config)
      refute result.halted
    end
  end

  describe "inspect_bucket/2" do
    test "returns :not_found for unknown IP" do
      assert :not_found = RateLimiter.inspect_bucket("unknown-ip", :login)
    end

    test "returns bucket state after request" do
      config = RateLimiter.init([])

      conn =
        Plug.Test.conn(:post, "/api/v1/auth/login")
        |> Map.put(:remote_ip, {10, 0, 0, 40})

      RateLimiter.call(conn, config)

      assert {:ok, {tokens, _last_refill}} = RateLimiter.inspect_bucket("10.0.0.40", :login)
      assert tokens < 10.0
    end
  end
end
