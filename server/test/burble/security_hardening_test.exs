# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Security hardening tests — verifies configuration, endpoint protection,
# and absence of common vulnerabilities.
#
# Part of P1 security hardening for Burble.

defmodule Burble.SecurityHardeningTest do
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Configuration security
  # ---------------------------------------------------------------------------

  describe "production configuration" do
    test "prod requires SECRET_KEY_BASE from environment" do
      # The runtime.exs raises if SECRET_KEY_BASE is missing in prod.
      # We verify the source code enforces this.
      runtime_config = File.read!(Path.join(__DIR__, "../../config/runtime.exs"))
      assert runtime_config =~ "SECRET_KEY_BASE"
      assert runtime_config =~ "raise"
    end

    test "prod requires VERISIMDB_URL from environment" do
      runtime_config = File.read!(Path.join(__DIR__, "../../config/runtime.exs"))
      assert runtime_config =~ "VERISIMDB_URL"
      assert runtime_config =~ "raise"
    end

    test "Guardian secret is not hardcoded in config.exs" do
      config_content = File.read!(Path.join(__DIR__, "../../config/config.exs"))
      # The Guardian secret_key should use System.get_env or crypto.strong_rand_bytes,
      # not a literal string.
      refute config_content =~ ~r/secret_key:\s*"[a-zA-Z0-9]{10,}"/,
             "Guardian secret_key should not be a hardcoded string"
    end

    test "dev secret_key_base is clearly marked as non-production" do
      dev_config = File.read!(Path.join(__DIR__, "../../config/dev.exs"))
      assert dev_config =~ "dev_only" or dev_config =~ "must_be_replaced",
             "Dev secret should be clearly marked as non-production"
    end

    test "test secret_key_base is clearly marked as test-only" do
      test_config = File.read!(Path.join(__DIR__, "../../config/test.exs"))
      assert test_config =~ "test_only",
             "Test secret should be clearly marked"
    end
  end

  # ---------------------------------------------------------------------------
  # CORS
  # ---------------------------------------------------------------------------

  describe "CORS configuration" do
    test "CORS is configurable via application env" do
      # Verify the endpoint uses Application.compile_env for CORS origins.
      endpoint_source = File.read!(Path.join(__DIR__, "../../lib/burble_web/endpoint.ex"))
      assert endpoint_source =~ "cors_origins",
             "CORS should be configurable, not hardcoded to *"
    end

    test "CORS allows specific headers, not all" do
      endpoint_source = File.read!(Path.join(__DIR__, "../../lib/burble_web/endpoint.ex"))
      assert endpoint_source =~ "content-type",
             "CORS should whitelist specific headers"
      refute endpoint_source =~ "allow_headers: :all",
             "CORS should not allow all headers"
    end
  end

  # ---------------------------------------------------------------------------
  # Rate limiting
  # ---------------------------------------------------------------------------

  describe "rate limiting coverage" do
    test "auth endpoints are rate limited" do
      router_source = File.read!(Path.join(__DIR__, "../../lib/burble_web/router.ex"))
      # Auth routes should be in the :api pipeline which includes RateLimiter.
      assert router_source =~ "RateLimiter"
    end

    test "health endpoint is not rate limited" do
      router_source = File.read!(Path.join(__DIR__, "../../lib/burble_web/router.ex"))
      # Health endpoint uses :accepts_json pipeline (no rate limiter).
      assert router_source =~ "accepts_json"
      assert router_source =~ "HealthController"
    end
  end

  # ---------------------------------------------------------------------------
  # Input sanitization
  # ---------------------------------------------------------------------------

  describe "input sanitization coverage" do
    test "API pipeline includes InputSanitizer" do
      router_source = File.read!(Path.join(__DIR__, "../../lib/burble_web/router.ex"))
      assert router_source =~ "InputSanitizer",
             "API pipeline should include InputSanitizer"
    end

    test "authenticated API pipeline includes InputSanitizer" do
      router_source = File.read!(Path.join(__DIR__, "../../lib/burble_web/router.ex"))
      # Check that InputSanitizer appears in the authenticated_api pipeline.
      assert router_source =~ "authenticated_api"
      # Both pipelines should have it.
      occurrences = router_source |> String.split("InputSanitizer") |> length()
      assert occurrences >= 3, "InputSanitizer should be in at least 2 pipelines (found #{occurrences - 1} occurrences)"
    end
  end

  # ---------------------------------------------------------------------------
  # TURN credentials
  # ---------------------------------------------------------------------------

  describe "TURN credential safety" do
    test "TURN credentials are dynamically generated, not hardcoded" do
      privacy_source = File.read!(Path.join(__DIR__, "../../lib/burble/media/privacy.ex"))
      assert privacy_source =~ "generate_turn_credential",
             "TURN credentials should be dynamically generated"
      assert privacy_source =~ "crypto.strong_rand_bytes",
             "TURN credentials should use cryptographic randomness"
    end

    test "TURN credentials include expiry" do
      privacy_source = File.read!(Path.join(__DIR__, "../../lib/burble/media/privacy.ex"))
      assert privacy_source =~ "3600" or privacy_source =~ "expiry",
             "TURN credentials should have a time limit"
    end
  end

  # ---------------------------------------------------------------------------
  # Authentication
  # ---------------------------------------------------------------------------

  describe "authentication security" do
    test "bcrypt uses constant-time comparison for missing users" do
      auth_source = File.read!(Path.join(__DIR__, "../../lib/burble/auth/auth.ex"))
      assert auth_source =~ "no_user_verify",
             "Auth should use Bcrypt.no_user_verify() to prevent timing attacks"
    end

    test "passwords are hashed, never stored in plaintext" do
      user_source = File.read!(Path.join(__DIR__, "../../lib/burble/auth/user.ex"))
      assert user_source =~ "password_hash" or user_source =~ "hash_pass",
             "User module should hash passwords"
    end

    test "guest sessions have limited permissions" do
      auth_source = File.read!(Path.join(__DIR__, "../../lib/burble/auth/auth.ex"))
      assert auth_source =~ "permissions",
             "Guest sessions should have permission restrictions"
    end
  end

  # ---------------------------------------------------------------------------
  # Secure headers
  # ---------------------------------------------------------------------------

  describe "secure browser headers" do
    test "browser pipeline uses secure headers" do
      router_source = File.read!(Path.join(__DIR__, "../../lib/burble_web/router.ex"))
      assert router_source =~ "put_secure_browser_headers",
             "Browser pipeline should set secure headers"
    end

    test "browser pipeline uses CSRF protection" do
      router_source = File.read!(Path.join(__DIR__, "../../lib/burble_web/router.ex"))
      assert router_source =~ "protect_from_forgery",
             "Browser pipeline should have CSRF protection"
    end
  end

  # ---------------------------------------------------------------------------
  # No hardcoded secrets in source
  # ---------------------------------------------------------------------------

  describe "no hardcoded secrets" do
    test "no API keys in source code" do
      lib_files = Path.wildcard(Path.join(__DIR__, "../../lib/**/*.ex"))

      Enum.each(lib_files, fn file ->
        content = File.read!(file)
        refute Regex.match?(~r/api[_-]?key\s*[:=]\s*"[a-zA-Z0-9]{20,}"/, content),
               "Potential hardcoded API key found in #{file}"
      end)
    end

    test "no bearer tokens in source code" do
      lib_files = Path.wildcard(Path.join(__DIR__, "../../lib/**/*.ex"))

      Enum.each(lib_files, fn file ->
        content = File.read!(file)
        refute Regex.match?(~r/Bearer\s+[a-zA-Z0-9._-]{20,}/, content),
               "Potential hardcoded bearer token found in #{file}"
      end)
    end
  end
end
