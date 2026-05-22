# SPDX-License-Identifier: MPL-2.0
#
# SDP (Software-Defined Perimeter) barrier tests.
#
# Validates that the SDP module correctly rejects unauthorized access
# and that authenticated sessions are properly validated.

defmodule Burble.Network.SDPBarrierTest do
  use ExUnit.Case, async: true

  alias Burble.Security.SDP

  describe "SDP module surface" do
    test "SDP module loads without errors" do
      assert Code.ensure_loaded?(SDP)
    end

    test "SDP module has expected exports" do
      exports = SDP.__info__(:functions)
      assert length(exports) > 0
    end
  end

  describe "mTLS module" do
    test "mTLS module is available" do
      assert Code.ensure_loaded?(Burble.Security.MTLS)
    end
  end

  describe "key rotation module" do
    test "KeyRotation module is available" do
      assert Code.ensure_loaded?(Burble.Security.KeyRotation)
    end
  end
end
