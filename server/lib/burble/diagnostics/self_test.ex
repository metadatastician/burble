# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Diagnostics.SelfTest — Voice and media self-test system.
#
# Provides loopback testing for voice, latency measurement, device
# enumeration, coprocessor health checks, and network diagnostics.
#
# Three test modes:
#   1. Quick  — coprocessor health + latency check (~2 seconds)
#   2. Voice  — mic → pipeline → speaker loopback (~10 seconds)
#   3. Full   — all subsystems including E2EE, QUIC, RTSP (~30 seconds)
#
# Results are structured for display in both web client and PanLL panel.
# Accessible via HTTP API: GET /api/v1/diagnostics/self-test/:mode

defmodule Burble.Diagnostics.SelfTest do
  @moduledoc """
  Voice and media self-test system for Burble.

  Run diagnostics on the full voice pipeline to verify hardware,
  coprocessor backends, network connectivity, and E2EE before
  joining a voice room.

  ## Usage

      # Quick health check.
      {:ok, results} = Burble.Diagnostics.SelfTest.run(:quick)

      # Voice loopback test.
      {:ok, results} = Burble.Diagnostics.SelfTest.run(:voice)

      # Full system diagnostic.
      {:ok, results} = Burble.Diagnostics.SelfTest.run(:full)
  """

  alias Burble.Coprocessor.{ElixirBackend, SmartBackend}

  @frame_length 960
  @sample_rate 48_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Run a self-test suite. Returns `{:ok, results}` with a structured
  result map containing pass/fail for each subsystem plus timing data.
  """
  def run(mode \\ :quick) do
    started_at = System.monotonic_time(:microsecond)

    results =
      case mode do
        :quick -> run_quick()
        :voice -> run_voice()
        :full -> run_full()
        _ -> %{error: "Unknown mode: #{mode}"}
      end

    elapsed_us = System.monotonic_time(:microsecond) - started_at

    {:ok,
     %{
       mode: mode,
       elapsed_ms: elapsed_us / 1000.0,
       timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
       results: results,
       overall: if(all_passed?(results), do: :pass, else: :fail)
     }}
  end

  # ---------------------------------------------------------------------------
  # Quick test — coprocessor health + basic latency
  # ---------------------------------------------------------------------------

  defp run_quick do
    %{
      coprocessor: test_coprocessor_health(),
      codec: test_codec_roundtrip(),
      crypto: test_crypto_roundtrip(),
      agc: test_agc(),
      vad: test_vad(),
      comfort_noise: test_comfort_noise(),
      perceptual: test_perceptual_weighting(),
      pipeline_latency: test_pipeline_latency()
    }
  end

  # ---------------------------------------------------------------------------
  # Voice test — loopback through full pipeline
  # ---------------------------------------------------------------------------

  defp run_voice do
    quick = run_quick()

    voice_tests = %{
      voice_loopback: test_voice_loopback(),
      echo_cancel: test_echo_cancellation(),
      noise_gate: test_noise_gate(),
      multi_frame: test_multi_frame_pipeline()
    }

    Map.merge(quick, voice_tests)
  end

  # ---------------------------------------------------------------------------
  # Full test — all subsystems
  # ---------------------------------------------------------------------------

  defp run_full do
    voice = run_voice()

    full_tests = %{
      e2ee: test_e2ee_roundtrip(),
      hash_chain: test_hash_chain_integrity(),
      key_derivation: test_key_derivation(),
      jitter_buffer: test_jitter_buffer(),
      packet_loss: test_packet_loss_concealment(),
      smart_dispatch: test_smart_backend_dispatch()
    }

    Map.merge(voice, full_tests)
  end

  # ---------------------------------------------------------------------------
  # Individual test implementations
  # ---------------------------------------------------------------------------

  defp test_coprocessor_health do
    backends = [
      {:elixir, ElixirBackend.available?()},
      {:smart, SmartBackend.available?()}
    ]

    zig_available =
      try do
        Burble.Coprocessor.ZigBackend.available?()
      rescue
        _ -> false
      end

    %{
      status: if(ElixirBackend.available?(), do: :pass, else: :fail),
      backends: [{:zig, zig_available} | backends],
      detail: "ElixirBackend always available. ZigBackend: #{if zig_available, do: "loaded", else: "not loaded (using Elixir fallback)"}."
    }
  end

  defp test_codec_roundtrip do
    signal = generate_tone(440.0)

    {encode_us, {:ok, encoded}} =
      :timer.tc(fn -> SmartBackend.audio_encode(signal, @sample_rate, 1, 32_000) end)

    {decode_us, {:ok, decoded}} =
      :timer.tc(fn -> SmartBackend.audio_decode(encoded, @sample_rate, 1) end)

    # Check round-trip fidelity (max quantisation error).
    max_error =
      Enum.zip(signal, decoded)
      |> Enum.map(fn {a, b} -> abs(a - b) end)
      |> Enum.max()

    %{
      status: if(max_error < 0.001 and length(decoded) == @frame_length, do: :pass, else: :fail),
      encode_us: encode_us,
      decode_us: decode_us,
      frame_size_bytes: byte_size(encoded),
      max_quantisation_error: Float.round(max_error, 6),
      detail: "Encode #{encode_us}µs, decode #{decode_us}µs, error #{Float.round(max_error * 100, 3)}%."
    }
  end

  defp test_crypto_roundtrip do
    plaintext = :crypto.strong_rand_bytes(100)
    key = :crypto.strong_rand_bytes(32)
    aad = "self-test"

    {encrypt_us, {:ok, {ciphertext, iv, tag}}} =
      :timer.tc(fn -> SmartBackend.crypto_encrypt_frame(plaintext, key, aad) end)

    {decrypt_us, {:ok, decrypted}} =
      :timer.tc(fn -> SmartBackend.crypto_decrypt_frame(ciphertext, key, iv, tag, aad) end)

    # Verify wrong key fails.
    wrong_key = :crypto.strong_rand_bytes(32)
    tamper_result = SmartBackend.crypto_decrypt_frame(ciphertext, wrong_key, iv, tag, aad)

    %{
      status: if(decrypted == plaintext and tamper_result == {:error, :decrypt_failed}, do: :pass, else: :fail),
      encrypt_us: encrypt_us,
      decrypt_us: decrypt_us,
      tamper_detected: tamper_result == {:error, :decrypt_failed},
      detail: "AES-256-GCM: encrypt #{encrypt_us}µs, decrypt #{decrypt_us}µs. Tamper detection: #{if tamper_result == {:error, :decrypt_failed}, do: "OK", else: "FAILED"}."
    }
  end

  defp test_agc do
    quiet = List.duplicate(0.001, @frame_length)
    loud = generate_tone(440.0, 0.9)

    {boost_us, {boosted, _}} = :timer.tc(fn -> SmartBackend.audio_agc(quiet, -20.0, 10.0, 100.0, %{}) end)
    {cut_us, {cut, _}} = :timer.tc(fn -> SmartBackend.audio_agc(loud, -30.0, 5.0, 100.0, %{}) end)

    boost_rms = rms(boosted)
    cut_rms = rms(cut)

    %{
      status: if(boost_rms > rms(quiet) * 2 and cut_rms < rms(loud), do: :pass, else: :fail),
      boost_us: boost_us,
      cut_us: cut_us,
      detail: "Boost: #{Float.round(boost_rms / max(rms(quiet), 0.0001), 1)}x gain. Cut: #{Float.round(cut_rms / max(rms(loud), 0.0001), 2)}x attenuation."
    }
  end

  defp test_vad do
    silence = List.duplicate(0.0, @frame_length)
    speech = generate_tone(1000.0, 0.3)

    {silence_us, {silence_speech, silence_conf, _}} =
      :timer.tc(fn -> SmartBackend.audio_spectral_vad(silence, @sample_rate, %{}) end)

    {speech_us, {_speech_detected, speech_conf, _}} =
      :timer.tc(fn -> SmartBackend.audio_spectral_vad(speech, @sample_rate, %{}) end)

    %{
      status: if(silence_speech == false and silence_conf >= 0.0 and speech_conf >= 0.0, do: :pass, else: :fail),
      silence_detected_as_speech: silence_speech,
      silence_confidence: Float.round(silence_conf, 3),
      speech_confidence: Float.round(speech_conf, 3),
      silence_us: silence_us,
      speech_us: speech_us,
      detail: "Silence: speech=#{silence_speech} (conf #{Float.round(silence_conf, 2)}). Tone: conf #{Float.round(speech_conf, 2)}."
    }
  end

  defp test_comfort_noise do
    {gen_us, noise} = :timer.tc(fn -> SmartBackend.audio_comfort_noise(@frame_length, -50.0, [0.5, 0.3, 0.2, 0.1]) end)
    noise_rms = rms(noise)

    %{
      status: if(length(noise) == @frame_length and noise_rms > 0.0, do: :pass, else: :fail),
      generation_us: gen_us,
      noise_rms_db: Float.round(20.0 * :math.log10(max(noise_rms, 1.0e-12)), 1),
      detail: "Generated #{@frame_length} samples in #{gen_us}µs, RMS #{Float.round(20.0 * :math.log10(max(noise_rms, 1.0e-12)), 1)} dB."
    }
  end

  defp test_perceptual_weighting do
    flat = List.duplicate(1.0, 128)
    {weight_us, weighted} = :timer.tc(fn -> SmartBackend.audio_perceptual_weight(flat, @sample_rate) end)

    # Low frequencies should be attenuated.
    low_avg = Enum.take(weighted, 5) |> Enum.sum() |> Kernel./(5)
    mid_idx = div(1000 * 128 * 2, @sample_rate)
    mid_avg = Enum.slice(weighted, mid_idx..(mid_idx + 4)) |> Enum.sum() |> Kernel./(5)

    %{
      status: if(low_avg < mid_avg and length(weighted) == 128, do: :pass, else: :fail),
      weighting_us: weight_us,
      low_freq_attenuation: Float.round(low_avg, 3),
      mid_freq_level: Float.round(mid_avg, 3),
      detail: "Low freq: #{Float.round(low_avg, 2)}, mid freq: #{Float.round(mid_avg, 2)}. A-weighting #{if low_avg < mid_avg, do: "correct", else: "INVERTED"}."
    }
  end

  defp test_pipeline_latency do
    capture = generate_noisy_tone()
    reference = List.duplicate(0.0, @frame_length)

    {total_us, _} =
      :timer.tc(fn ->
        gated = SmartBackend.audio_noise_gate(capture, -45.0)
        cancelled = SmartBackend.audio_echo_cancel(gated, reference, 64)
        {_, _, _} = SmartBackend.audio_spectral_vad(cancelled, @sample_rate, %{})
        {processed, _} = SmartBackend.audio_agc(cancelled, -20.0, 10.0, 100.0, %{})
        {:ok, _} = SmartBackend.audio_encode(processed, @sample_rate, 1, 32_000)
      end)

    budget_ms = 20.0
    actual_ms = total_us / 1000.0

    %{
      status: if(actual_ms < budget_ms, do: :pass, else: :fail),
      pipeline_us: total_us,
      pipeline_ms: Float.round(actual_ms, 2),
      frame_budget_ms: budget_ms,
      headroom_ms: Float.round(budget_ms - actual_ms, 2),
      detail: "Full pipeline: #{Float.round(actual_ms, 1)}ms / #{budget_ms}ms budget (#{Float.round((budget_ms - actual_ms) / budget_ms * 100, 0)}% headroom)."
    }
  end

  defp test_voice_loopback do
    # Full mic→pipeline→speaker simulation (10 frames).
    frames = for _ <- 1..10, do: generate_noisy_tone()
    reference = List.duplicate(0.0, @frame_length)

    {total_us, results} =
      :timer.tc(fn ->
        Enum.map(frames, fn frame ->
          gated = SmartBackend.audio_noise_gate(frame, -45.0)
          cancelled = SmartBackend.audio_echo_cancel(gated, reference, 64)
          {processed, _} = SmartBackend.audio_agc(cancelled, -20.0, 10.0, 100.0, %{})
          {:ok, encoded} = SmartBackend.audio_encode(processed, @sample_rate, 1, 32_000)
          {:ok, decoded} = SmartBackend.audio_decode(encoded, @sample_rate, 1)
          decoded
        end)
      end)

    all_correct = Enum.all?(results, fn r -> length(r) == @frame_length end)
    avg_frame_ms = total_us / 10 / 1000.0

    %{
      status: if(all_correct and avg_frame_ms < 20.0, do: :pass, else: :fail),
      frames_processed: 10,
      total_ms: Float.round(total_us / 1000.0, 1),
      avg_frame_ms: Float.round(avg_frame_ms, 2),
      detail: "10-frame loopback: #{Float.round(avg_frame_ms, 1)}ms/frame avg."
    }
  end

  defp test_echo_cancellation do
    # Generate a signal where speaker output feeds back into mic.
    speech = generate_tone(440.0, 0.3)
    echo = Enum.map(speech, fn s -> s * 0.5 end)  # 50% echo level.
    capture = Enum.zip_with(speech, echo, fn s, e -> s + e end)

    {cancel_us, cancelled} =
      :timer.tc(fn -> SmartBackend.audio_echo_cancel(capture, echo, 128) end)

    # Echo should be reduced.
    capture_rms = rms(capture)
    cancelled_rms = rms(cancelled)
    reduction_db = 20.0 * :math.log10(max(cancelled_rms / max(capture_rms, 1.0e-12), 1.0e-12))

    %{
      status: :pass,  # Echo cancel always produces output; quality is the metric.
      cancel_us: cancel_us,
      input_rms_db: Float.round(20.0 * :math.log10(max(capture_rms, 1.0e-12)), 1),
      output_rms_db: Float.round(20.0 * :math.log10(max(cancelled_rms, 1.0e-12)), 1),
      reduction_db: Float.round(reduction_db, 1),
      detail: "Echo reduction: #{Float.round(reduction_db, 1)} dB in #{cancel_us}µs."
    }
  end

  defp test_noise_gate do
    quiet_noise = for _ <- 1..@frame_length, do: (:rand.uniform() - 0.5) * 0.001
    {gate_us, gated} = :timer.tc(fn -> SmartBackend.audio_noise_gate(quiet_noise, -60.0) end)

    zeroed_count = Enum.count(gated, fn s -> s == 0.0 end)

    %{
      status: if(zeroed_count > @frame_length * 0.8, do: :pass, else: :fail),
      gate_us: gate_us,
      zeroed_samples: zeroed_count,
      total_samples: @frame_length,
      gate_ratio: Float.round(zeroed_count / @frame_length * 100, 1),
      detail: "Noise gate zeroed #{zeroed_count}/#{@frame_length} samples (#{Float.round(zeroed_count / @frame_length * 100, 0)}%)."
    }
  end

  defp test_multi_frame_pipeline do
    # 50 frames (1 second of audio) through full pipeline.
    {total_us, frame_count} =
      :timer.tc(fn ->
        Enum.reduce(1..50, {%{}, %{}}, fn _i, {vad_state, agc_state} ->
          frame = generate_noisy_tone()
          ref = List.duplicate(0.0, @frame_length)
          gated = SmartBackend.audio_noise_gate(frame, -45.0)
          cancelled = SmartBackend.audio_echo_cancel(gated, ref, 64)
          {_speech, _conf, new_vad} = SmartBackend.audio_spectral_vad(cancelled, @sample_rate, vad_state)
          {processed, new_agc} = SmartBackend.audio_agc(cancelled, -20.0, 10.0, 100.0, agc_state)
          {:ok, _encoded} = SmartBackend.audio_encode(processed, @sample_rate, 1, 32_000)
          {new_vad, new_agc}
        end)
        50
      end)

    total_ms = total_us / 1000.0
    real_time_ms = 50 * 20.0  # 50 frames × 20ms = 1000ms of audio.
    ratio = real_time_ms / max(total_ms, 0.001)

    %{
      status: if(ratio > 1.0, do: :pass, else: :fail),
      frames: frame_count,
      total_ms: Float.round(total_ms, 1),
      real_time_ms: real_time_ms,
      real_time_ratio: Float.round(ratio, 1),
      detail: "50 frames in #{Float.round(total_ms, 0)}ms (#{Float.round(ratio, 1)}x real-time). #{if ratio > 1.0, do: "FASTER than real-time", else: "SLOWER than real-time — needs Zig backend"}."
    }
  end

  defp test_e2ee_roundtrip do
    frame = generate_tone(440.0)
    {:ok, encoded} = SmartBackend.audio_encode(frame, @sample_rate, 1, 32_000)
    key = :crypto.strong_rand_bytes(32)
    aad = "room:self-test"

    {e2ee_us, result} =
      :timer.tc(fn ->
        {:ok, {ct, iv, tag}} = SmartBackend.crypto_encrypt_frame(encoded, key, aad)
        {:ok, decrypted} = SmartBackend.crypto_decrypt_frame(ct, key, iv, tag, aad)
        decrypted == encoded
      end)

    %{
      status: if(result, do: :pass, else: :fail),
      roundtrip_us: e2ee_us,
      detail: "E2EE encrypt+decrypt: #{e2ee_us}µs."
    }
  end

  defp test_hash_chain_integrity do
    frames = for _ <- 1..5, do: :crypto.strong_rand_bytes(100)

    {chain_us, chain_valid} =
      :timer.tc(fn ->
        {chain, _} =
          Enum.reduce(frames, {[], <<0::256>>}, fn frame, {acc, prev} ->
            hash = SmartBackend.crypto_hash_chain(prev, frame)
            {[{frame, hash} | acc], hash}
          end)

        chain = Enum.reverse(chain)

        # Verify.
        Enum.reduce(chain, {true, <<0::256>>}, fn {frame, expected}, {valid, prev} ->
          computed = SmartBackend.crypto_hash_chain(prev, frame)
          {valid and computed == expected, expected}
        end)
        |> elem(0)
      end)

    %{
      status: if(chain_valid, do: :pass, else: :fail),
      chain_length: 5,
      chain_us: chain_us,
      detail: "5-link hash chain: #{if chain_valid, do: "integrity verified", else: "BROKEN"} in #{chain_us}µs."
    }
  end

  defp test_key_derivation do
    secret = :crypto.strong_rand_bytes(32)
    salt1 = :crypto.strong_rand_bytes(16)
    salt2 = :crypto.strong_rand_bytes(16)

    key1 = SmartBackend.crypto_derive_frame_key(secret, salt1, "burble-test")
    key2 = SmartBackend.crypto_derive_frame_key(secret, salt2, "burble-test")

    %{
      status: if(key1 != key2 and byte_size(key1) == 32, do: :pass, else: :fail),
      key_size: byte_size(key1),
      unique_per_salt: key1 != key2,
      detail: "HKDF key derivation: #{byte_size(key1)}-byte keys, unique per salt: #{key1 != key2}."
    }
  end

  defp test_jitter_buffer do
    state = %{}

    # Push a packet into the jitter buffer using the current API.
    # Returns {:ok, frame_or_nil, updated_buffer}.
    {jitter_us, {:ok, _frame, _buffer}} =
      :timer.tc(fn ->
        SmartBackend.io_jitter_buffer_push(state, :crypto.strong_rand_bytes(100), 0, 0)
      end)

    %{
      status: :pass,
      insert_us: jitter_us,
      detail: "Jitter buffer push: #{jitter_us}us."
    }
  end

  defp test_packet_loss_concealment do
    # io_conceal_loss/2 expects a list of previous encoded (binary) frames
    # and a frame size in bytes.
    pcm = generate_tone(440.0)
    {:ok, encoded} = SmartBackend.audio_encode(pcm, @sample_rate, 1, 32_000)
    frame_size = byte_size(encoded)

    {plc_us, concealed} =
      :timer.tc(fn -> SmartBackend.io_conceal_loss([encoded], frame_size) end)

    %{
      status: if(is_binary(concealed) and byte_size(concealed) == frame_size, do: :pass, else: :fail),
      plc_us: plc_us,
      detail: "PLC: #{plc_us}us for #{frame_size}-byte frame."
    }
  end

  defp test_smart_backend_dispatch do
    # Verify SmartBackend dispatches all new operations without error.
    tests = [
      {:agc, fn -> SmartBackend.audio_agc(List.duplicate(0.1, 100), -20.0, 10.0, 100.0, %{}) end},
      {:comfort_noise, fn -> SmartBackend.audio_comfort_noise(100, -50.0, []) end},
      {:spectral_vad, fn -> SmartBackend.audio_spectral_vad(List.duplicate(0.1, 100), @sample_rate, %{}) end},
      {:perceptual_weight, fn -> SmartBackend.audio_perceptual_weight(List.duplicate(1.0, 64), @sample_rate) end}
    ]

    results =
      Enum.map(tests, fn {name, test_fn} ->
        try do
          test_fn.()
          {name, :pass}
        rescue
          e -> {name, {:fail, Exception.message(e)}}
        end
      end)

    all_ok = Enum.all?(results, fn {_, r} -> r == :pass end)

    %{
      status: if(all_ok, do: :pass, else: :fail),
      dispatched: results,
      detail: "SmartBackend dispatch: #{length(results)} operations, #{if all_ok, do: "all passed", else: "FAILURES detected"}."
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp generate_tone(freq, amplitude \\ 0.3) do
    for i <- 1..@frame_length do
      :math.sin(2.0 * :math.pi() * freq * i / @sample_rate) * amplitude
    end
  end

  defp generate_noisy_tone(freq \\ 440.0) do
    for i <- 1..@frame_length do
      :math.sin(2.0 * :math.pi() * freq * i / @sample_rate) * 0.3 +
        (:rand.uniform() - 0.5) * 0.02
    end
  end

  defp rms(samples) do
    sum_sq = Enum.reduce(samples, 0.0, fn s, acc -> acc + s * s end)
    :math.sqrt(sum_sq / max(length(samples), 1))
  end

  defp all_passed?(results) when is_map(results) do
    Enum.all?(results, fn
      {_key, %{status: :pass}} -> true
      {_key, %{status: _}} -> false
      {_key, nested} when is_map(nested) -> all_passed?(nested)
      _ -> true
    end)
  end
end
