# SPDX-License-Identifier: MPL-2.0
#
# Tests for Burble.Safety.ProvenBridge — formally verified safety wrappers.
#
# The proven NIF is not installed in the test environment, so every test
# exercises the fallback (Erlang stdlib) paths. Tests also verify that
# proven_available?/0 reports correctly and that the public API surface
# matches the module spec.

defmodule Burble.Safety.ProvenBridgeTest do
  use ExUnit.Case, async: true

  alias Burble.Safety.ProvenBridge

  describe "module" do
    test "Burble.Safety.ProvenBridge is loaded" do
      assert Code.ensure_loaded?(Burble.Safety.ProvenBridge)
    end

    test "proven_available?/0 reports the NIF absent in the test environment" do
      # This file's moduledoc states the proven NIF is not installed under
      # test, so every other test here exercises the stdlib fallback. If
      # this ever returns true in CI, those fallback tests are silently
      # testing the wrong path — so pin the documented invariant.
      refute ProvenBridge.proven_available?()
    end
  end

  describe "constant_time_eq?/2 (fallback path)" do
    test "returns true for identical binaries" do
      assert ProvenBridge.constant_time_eq?("hello", "hello")
    end

    test "returns false for different binaries" do
      refute ProvenBridge.constant_time_eq?("hello", "world")
    end

    test "returns false for different-length binaries" do
      refute ProvenBridge.constant_time_eq?("abc", "abcd")
    end
  end

  describe "validate_password_strength/1 (fallback path)" do
    test "accepts a long-enough password" do
      assert {:ok, _strength} = ProvenBridge.validate_password_strength("securepass123")
    end

    test "rejects a short password" do
      assert {:error, _} = ProvenBridge.validate_password_strength("short")
    end
  end

  describe "secure_random/1 (fallback path)" do
    test "returns a binary of requested length" do
      result = ProvenBridge.secure_random(16)
      assert is_binary(result)
      assert byte_size(result) == 16
    end
  end

  describe "validate_email/1 (fallback path)" do
    test "accepts a valid email address" do
      assert {:ok, "test@example.com"} = ProvenBridge.validate_email("test@example.com")
    end

    test "normalises email to lowercase" do
      assert {:ok, "user@example.com"} = ProvenBridge.validate_email("User@Example.COM")
    end

    test "rejects a string without @" do
      assert {:error, :invalid_email} = ProvenBridge.validate_email("notanemail")
    end
  end

  describe "safe_path/1 (fallback path)" do
    test "accepts a normal path" do
      assert {:ok, "/recordings/room-1/audio.ogg"} =
               ProvenBridge.safe_path("/recordings/room-1/audio.ogg")
    end

    test "rejects a path traversal attempt" do
      assert {:error, :unsafe_path} = ProvenBridge.safe_path("../../../etc/passwd")
    end
  end
end
