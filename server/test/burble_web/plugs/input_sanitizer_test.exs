# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for BurbleWeb.Plugs.InputSanitizer — input validation plug.
#
# Verifies that malicious, oversized, and malformed inputs are rejected
# before reaching controllers.

defmodule BurbleWeb.Plugs.InputSanitizerTest do
  use ExUnit.Case, async: true

  alias BurbleWeb.Plugs.InputSanitizer

  # ---------------------------------------------------------------------------
  # validate_params/1 — direct function tests
  # ---------------------------------------------------------------------------

  describe "validate_params/1 — ID fields" do
    test "accepts valid room_id" do
      assert :ok = InputSanitizer.validate_params(%{"room_id" => "test-room-abc123"})
    end

    test "accepts valid server_id with underscores" do
      assert :ok = InputSanitizer.validate_params(%{"server_id" => "my_server_42"})
    end

    test "rejects room_id with path traversal" do
      assert {:error, "room_id", _} = InputSanitizer.validate_params(%{"room_id" => "../../../etc/passwd"})
    end

    test "rejects room_id with spaces" do
      assert {:error, "room_id", _} = InputSanitizer.validate_params(%{"room_id" => "room with spaces"})
    end

    test "rejects room_id with special characters" do
      assert {:error, "room_id", _} = InputSanitizer.validate_params(%{"room_id" => "room<script>alert(1)</script>"})
    end

    test "rejects excessively long room_id" do
      long_id = String.duplicate("a", 200)
      assert {:error, "room_id", msg} = InputSanitizer.validate_params(%{"room_id" => long_id})
      assert msg =~ "maximum length"
    end
  end

  describe "validate_params/1 — display names" do
    test "accepts normal display name" do
      assert :ok = InputSanitizer.validate_params(%{"display_name" => "Alice"})
    end

    test "accepts Unicode display name" do
      assert :ok = InputSanitizer.validate_params(%{"display_name" => "Aloïs-René"})
    end

    test "rejects display name with control characters" do
      assert {:error, "display_name", _} = InputSanitizer.validate_params(%{"display_name" => "Alice\x00Bob"})
    end

    test "rejects excessively long display name" do
      long_name = String.duplicate("a", 100)
      assert {:error, "display_name", msg} = InputSanitizer.validate_params(%{"display_name" => long_name})
      assert msg =~ "maximum length"
    end
  end

  describe "validate_params/1 — email" do
    test "accepts valid email" do
      assert :ok = InputSanitizer.validate_params(%{"email" => "user@example.com"})
    end

    test "rejects email without @" do
      assert {:error, "email", _} = InputSanitizer.validate_params(%{"email" => "not-an-email"})
    end

    test "rejects email without domain" do
      assert {:error, "email", _} = InputSanitizer.validate_params(%{"email" => "user@"})
    end
  end

  describe "validate_params/1 — null bytes" do
    test "rejects null bytes in any string field" do
      assert {:error, "name", msg} = InputSanitizer.validate_params(%{"name" => "test\x00evil"})
      assert msg =~ "null byte"
    end

    test "rejects null bytes in password" do
      assert {:error, "password", msg} = InputSanitizer.validate_params(%{"password" => "pass\x00word"})
      assert msg =~ "null byte"
    end
  end

  describe "validate_params/1 — token fields" do
    test "accepts valid base64url token" do
      assert :ok = InputSanitizer.validate_params(%{"token" => "abc123-_DEF="})
    end

    test "accepts valid connect code" do
      assert :ok = InputSanitizer.validate_params(%{"code" => "abcdef123456"})
    end

    test "rejects code with shell injection characters" do
      assert {:error, "code", _} = InputSanitizer.validate_params(%{"code" => "abc; rm -rf /"})
    end
  end

  describe "validate_params/1 — non-string values" do
    test "passes through integer values" do
      assert :ok = InputSanitizer.validate_params(%{"max_participants" => 50})
    end

    test "passes through boolean values" do
      assert :ok = InputSanitizer.validate_params(%{"is_admin" => true})
    end

    test "passes through nil values" do
      assert :ok = InputSanitizer.validate_params(%{"optional" => nil})
    end
  end

  # ---------------------------------------------------------------------------
  # Plug call/2 — integration tests
  # ---------------------------------------------------------------------------

  describe "call/2 — plug behaviour" do
    test "passes valid request through" do
      config = InputSanitizer.init([])

      conn =
        Plug.Test.conn(:get, "/api/v1/rooms/test-room")
        |> Map.put(:params, %{"id" => "test-room"})

      result = InputSanitizer.call(conn, config)
      refute result.halted
    end

    test "rejects request with invalid parameter" do
      config = InputSanitizer.init([])

      conn =
        Plug.Test.conn(:post, "/api/v1/auth/register")
        |> Map.put(:params, %{"room_id" => "../../../etc/passwd"})

      result = InputSanitizer.call(conn, config)
      assert result.halted
      assert result.status == 400

      body = Jason.decode!(result.resp_body)
      assert body["error"] == "invalid_input"
      assert body["field"] == "room_id"
    end
  end
end
