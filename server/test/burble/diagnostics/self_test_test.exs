# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Tests for Burble.Diagnostics.SelfTest — voice pipeline diagnostics.
#
# Verifies that the self-test subsystem runs all three modes (quick, voice,
# full) and returns properly structured results.

defmodule Burble.Diagnostics.SelfTestTest do
  use ExUnit.Case, async: true

  alias Burble.Diagnostics.SelfTest

  describe "run/1 :quick mode" do
    test "returns :ok with structured results" do
      assert {:ok, results} = SelfTest.run(:quick)
      assert results.mode == :quick
      assert is_float(results.elapsed_ms)
      assert is_binary(results.timestamp)
      assert is_map(results.results)
      assert results.overall in [:pass, :fail]
    end

    test "quick mode checks coprocessor health" do
      {:ok, results} = SelfTest.run(:quick)
      assert Map.has_key?(results.results, :coprocessor)
      assert results.results.coprocessor.status in [:pass, :fail]
    end

    test "quick mode checks codec roundtrip" do
      {:ok, results} = SelfTest.run(:quick)
      assert Map.has_key?(results.results, :codec)
      assert results.results.codec.status in [:pass, :fail]
    end

    test "quick mode checks crypto" do
      {:ok, results} = SelfTest.run(:quick)
      assert Map.has_key?(results.results, :crypto)
      assert results.results.crypto.status == :pass
    end

    test "quick mode checks AGC" do
      {:ok, results} = SelfTest.run(:quick)
      assert Map.has_key?(results.results, :agc)
    end

    test "quick mode checks VAD" do
      {:ok, results} = SelfTest.run(:quick)
      assert Map.has_key?(results.results, :vad)
    end

    test "quick mode checks pipeline latency" do
      {:ok, results} = SelfTest.run(:quick)
      assert Map.has_key?(results.results, :pipeline_latency)
      assert is_number(results.results.pipeline_latency.pipeline_ms)
    end
  end

  describe "run/1 :voice mode" do
    test "includes all quick tests plus voice-specific tests" do
      {:ok, results} = SelfTest.run(:voice)
      assert results.mode == :voice

      # Should have all quick tests.
      assert Map.has_key?(results.results, :coprocessor)
      assert Map.has_key?(results.results, :codec)
      assert Map.has_key?(results.results, :crypto)

      # Plus voice-specific tests.
      assert Map.has_key?(results.results, :voice_loopback)
      assert Map.has_key?(results.results, :echo_cancel)
      assert Map.has_key?(results.results, :noise_gate)
      assert Map.has_key?(results.results, :multi_frame)
    end
  end

  describe "run/1 :full mode" do
    test "includes all tests" do
      {:ok, results} = SelfTest.run(:full)
      assert results.mode == :full

      # Should have voice tests.
      assert Map.has_key?(results.results, :voice_loopback)

      # Plus full-mode tests.
      assert Map.has_key?(results.results, :e2ee)
      assert Map.has_key?(results.results, :hash_chain)
      assert Map.has_key?(results.results, :key_derivation)
    end
  end

  describe "run/1 with unknown mode" do
    test "returns error for invalid mode" do
      {:ok, results} = SelfTest.run(:invalid)
      assert Map.has_key?(results.results, :error)
    end
  end
end
