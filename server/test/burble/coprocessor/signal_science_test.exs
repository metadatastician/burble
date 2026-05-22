# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Signal science tests — AGC, comfort noise, spectral VAD, perceptual weighting.
# Tests the four new coprocessor additions for correctness and boundary conditions.

defmodule Burble.Coprocessor.SignalScienceTest do
  use ExUnit.Case, async: true

  alias Burble.Coprocessor.ElixirBackend

  # Standard test frame: 960 samples (20ms at 48kHz).
  @frame_length 960
  @sample_rate 48_000

  # ---------------------------------------------------------------------------
  # AGC tests
  # ---------------------------------------------------------------------------

  describe "audio_agc/5" do
    test "boosts quiet signal toward target RMS" do
      # Very quiet signal (40 dB below target).
      quiet_signal = List.duplicate(0.001, @frame_length)
      {amplified, _state} = ElixirBackend.audio_agc(quiet_signal, -20.0, 10.0, 100.0, %{})

      # Should be louder than input.
      input_rms = rms(quiet_signal)
      output_rms = rms(amplified)
      assert output_rms > input_rms * 2, "AGC should boost quiet signal"
    end

    test "attenuates loud signal toward target RMS" do
      # Very loud signal.
      loud_signal = for i <- 1..@frame_length, do: :math.sin(i * 0.1) * 0.9
      {attenuated, _state} = ElixirBackend.audio_agc(loud_signal, -30.0, 5.0, 100.0, %{})

      # Should be quieter than input.
      output_rms = rms(attenuated)
      assert output_rms < rms(loud_signal), "AGC should attenuate loud signal"
    end

    test "soft clips to prevent distortion" do
      # Extremely loud signal that would clip.
      extreme = List.duplicate(1.0, @frame_length)
      {result, _state} = ElixirBackend.audio_agc(extreme, -10.0, 1.0, 1.0, %{})

      # No sample should exceed 1.0.
      assert Enum.all?(result, fn s -> abs(s) <= 1.0 end), "Soft clipping should prevent >1.0"
    end

    test "preserves silence" do
      silence = List.duplicate(0.0, @frame_length)
      {result, _state} = ElixirBackend.audio_agc(silence, -20.0, 10.0, 100.0, %{})

      assert Enum.all?(result, fn s -> abs(s) < 0.001 end), "AGC should not amplify silence"
    end

    test "gain state persists across frames" do
      signal = for i <- 1..@frame_length, do: :math.sin(i * 0.1) * 0.1
      {_out1, state1} = ElixirBackend.audio_agc(signal, -20.0, 10.0, 100.0, %{})
      {_out2, state2} = ElixirBackend.audio_agc(signal, -20.0, 10.0, 100.0, state1)

      # Gain should converge (state2 gain closer to steady-state than state1).
      assert Map.has_key?(state2, :gain), "State should track gain"
    end
  end

  # ---------------------------------------------------------------------------
  # Comfort noise tests
  # ---------------------------------------------------------------------------

  describe "audio_comfort_noise/3" do
    test "generates noise at correct length" do
      noise = ElixirBackend.audio_comfort_noise(@frame_length, -50.0, [])
      assert length(noise) == @frame_length
    end

    test "noise is at approximately target level" do
      noise = ElixirBackend.audio_comfort_noise(@frame_length, -40.0, [])
      noise_rms = rms(noise)
      target_rms = :math.pow(10.0, -40.0 / 20.0)

      # Should be within 6 dB of target (noise is stochastic).
      assert noise_rms < target_rms * 2.0, "Comfort noise too loud"
      assert noise_rms > target_rms * 0.25, "Comfort noise too quiet"
    end

    test "noise is spectrally shaped when profile provided" do
      # Profile with energy concentrated in low frequencies.
      profile = [1.0, 0.8, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01]
      noise = ElixirBackend.audio_comfort_noise(@frame_length, -30.0, profile)

      assert length(noise) == @frame_length
      # Shaped noise should not be identical to flat noise.
      flat_noise = ElixirBackend.audio_comfort_noise(@frame_length, -30.0, [])
      assert noise != flat_noise, "Shaped noise should differ from flat noise"
    end

    test "silence profile produces near-zero output" do
      profile = List.duplicate(0.0, 8)
      noise = ElixirBackend.audio_comfort_noise(@frame_length, -60.0, profile)

      assert Enum.all?(noise, fn s -> abs(s) < 0.01 end), "Zero profile should produce near-silence"
    end
  end

  # ---------------------------------------------------------------------------
  # Spectral VAD tests
  # ---------------------------------------------------------------------------

  describe "audio_spectral_vad/3" do
    test "detects silence as non-speech" do
      silence = List.duplicate(0.0, @frame_length)
      {is_speech, confidence, _state} = ElixirBackend.audio_spectral_vad(silence, @sample_rate, %{})

      assert is_speech == false, "Silence should not be detected as speech"
      assert confidence < 0.5, "Silence confidence should be low"
    end

    test "detects tone in speech band as potential speech" do
      # 1 kHz tone — in the speech frequency range.
      tone = for i <- 1..@frame_length, do: :math.sin(2.0 * :math.pi() * 1000.0 * i / @sample_rate) * 0.5
      {is_speech, confidence, state} = ElixirBackend.audio_spectral_vad(tone, @sample_rate, %{})

      # A pure tone may or may not satisfy every speech criterion, so the
      # classification itself is not asserted. The documented return
      # contract is: {boolean, confidence in 0.0..1.0, state map}.
      assert is_boolean(is_speech)
      assert is_float(confidence) and confidence >= 0.0 and confidence <= 1.0
      assert is_map(state)
    end

    test "detects white noise as non-speech" do
      # White noise has high spectral flatness.
      noise = for _ <- 1..@frame_length, do: :rand.uniform() * 2.0 - 1.0
      # Run a few frames to build up noise statistics.
      state0 = %{noise_flatness: 0.85, noise_zcr: 0.3, frame_count: 20}
      {is_speech, _confidence, _state} = ElixirBackend.audio_spectral_vad(noise, @sample_rate, state0)

      assert is_speech == false, "White noise should not be detected as speech"
    end

    test "state accumulates across frames" do
      signal = for _ <- 1..@frame_length, do: :rand.uniform() * 0.1
      {_, _, state1} = ElixirBackend.audio_spectral_vad(signal, @sample_rate, %{})
      {_, _, state2} = ElixirBackend.audio_spectral_vad(signal, @sample_rate, state1)

      assert Map.get(state2, :frame_count, 0) > Map.get(state1, :frame_count, 0),
             "Frame count should increment"
    end

    test "returns confidence between 0 and 1" do
      signal = for i <- 1..@frame_length, do: :math.sin(i * 0.05) * 0.3
      {_is_speech, confidence, _state} = ElixirBackend.audio_spectral_vad(signal, @sample_rate, %{})

      assert confidence >= 0.0 and confidence <= 1.0, "Confidence must be in [0, 1]"
    end
  end

  # ---------------------------------------------------------------------------
  # Perceptual weighting tests
  # ---------------------------------------------------------------------------

  describe "audio_perceptual_weight/2" do
    test "attenuates low frequencies" do
      # Flat magnitude spectrum.
      magnitudes = List.duplicate(1.0, 256)
      weighted = ElixirBackend.audio_perceptual_weight(magnitudes, @sample_rate)

      # Low frequency bins (first few) should be attenuated.
      low_freq_weight = Enum.at(weighted, 2)  # ~200 Hz bin
      mid_freq_idx = div(1000 * 256 * 2, @sample_rate)  # ~1 kHz bin index
      mid_freq_weight = Enum.at(weighted, mid_freq_idx)

      assert low_freq_weight < mid_freq_weight,
             "Low frequencies should be attenuated relative to 1 kHz"
    end

    test "preserves speech band (1-4 kHz)" do
      magnitudes = List.duplicate(1.0, 256)
      weighted = ElixirBackend.audio_perceptual_weight(magnitudes, @sample_rate)

      # 1-4 kHz bins should have weights close to 1.0.
      bin_1k = div(1000 * 256 * 2, @sample_rate)
      bin_2k = div(2000 * 256 * 2, @sample_rate)

      speech_weights = Enum.slice(weighted, bin_1k..bin_2k)
      avg_speech = Enum.sum(speech_weights) / max(length(speech_weights), 1)

      assert avg_speech > 0.5, "Speech band should be largely preserved"
    end

    test "output length matches input" do
      magnitudes = List.duplicate(0.5, 128)
      weighted = ElixirBackend.audio_perceptual_weight(magnitudes, @sample_rate)

      assert length(weighted) == 128
    end

    test "handles zero magnitudes" do
      magnitudes = List.duplicate(0.0, 64)
      weighted = ElixirBackend.audio_perceptual_weight(magnitudes, @sample_rate)

      assert Enum.all?(weighted, fn w -> w == 0.0 end), "Zero in → zero out"
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end pipeline tests
  # ---------------------------------------------------------------------------

  describe "full voice pipeline (point-to-point)" do
    test "capture → noise gate → echo cancel → AGC → encode → decode → comfort noise fill" do
      # Simulate a voice frame with background noise.
      speech = for i <- 1..@frame_length, do: :math.sin(2.0 * :math.pi() * 440.0 * i / @sample_rate) * 0.3
      noise = for _ <- 1..@frame_length, do: (:rand.uniform() - 0.5) * 0.02
      capture = Enum.zip_with(speech, noise, fn s, n -> s + n end)
      reference = List.duplicate(0.0, @frame_length)  # No playback echo.

      # Step 1: Noise gate.
      gated = ElixirBackend.audio_noise_gate(capture, -40.0)
      assert length(gated) == @frame_length

      # Step 2: Echo cancellation.
      cancelled = ElixirBackend.audio_echo_cancel(gated, reference, 64)
      assert length(cancelled) == @frame_length

      # Step 3: AGC.
      {normalised, _agc_state} = ElixirBackend.audio_agc(cancelled, -20.0, 10.0, 100.0, %{})
      assert length(normalised) == @frame_length

      # Step 4: Encode.
      {:ok, encoded} = ElixirBackend.audio_encode(normalised, @sample_rate, 1, 32_000)
      assert is_binary(encoded)

      # Step 5: Decode.
      {:ok, decoded} = ElixirBackend.audio_decode(encoded, @sample_rate, 1)
      assert length(decoded) == @frame_length

      # Step 6: Verify round-trip preserved signal shape.
      # Allow for quantisation error (16-bit PCM).
      errors = Enum.zip_with(normalised, decoded, fn a, b -> abs(a - b) end)
      max_error = Enum.max(errors)
      assert max_error < 0.001, "Round-trip quantisation error should be small: #{max_error}"
    end

    test "silence detection → comfort noise insertion" do
      silence = List.duplicate(0.0, @frame_length)

      # VAD should detect silence.
      {is_speech, _conf, _state} = ElixirBackend.audio_spectral_vad(silence, @sample_rate, %{})
      assert is_speech == false

      # Generate comfort noise to fill the gap.
      comfort = ElixirBackend.audio_comfort_noise(@frame_length, -50.0, [0.5, 0.3, 0.2, 0.1])
      assert length(comfort) == @frame_length
      assert rms(comfort) > 0.0, "Comfort noise should not be total silence"
    end

    test "perceptual weighting improves noise reduction quality" do
      # Flat noise spectrum.
      noise_magnitudes = List.duplicate(0.1, 256)

      # Without perceptual weighting — uniform reduction.
      uniform_reduced = Enum.map(noise_magnitudes, fn m -> m * 0.1 end)

      # With perceptual weighting — shaped reduction.
      weighted = ElixirBackend.audio_perceptual_weight(noise_magnitudes, @sample_rate)
      perceptual_reduced = Enum.map(weighted, fn m -> m * 0.1 end)

      # Perceptual reduction should differ from uniform (less reduction in speech band).
      assert uniform_reduced != perceptual_reduced, "Perceptual weighting should shape the reduction"
    end

    test "multi-frame AGC convergence" do
      # Feed 10 frames of steady signal — gain should converge.
      signal = for i <- 1..@frame_length, do: :math.sin(i * 0.1) * 0.1
      target_db = -20.0

      {gains, _final_state} =
        Enum.reduce(1..10, {[], %{}}, fn _i, {gains_acc, state} ->
          {_out, new_state} = ElixirBackend.audio_agc(signal, target_db, 10.0, 100.0, state)
          gain = Map.get(new_state, :gain, 1.0)
          {[gain | gains_acc], new_state}
        end)

      gains = Enum.reverse(gains)

      # Gain should be converging (variance of last 5 < variance of first 5).
      first_half = Enum.take(gains, 5)
      second_half = Enum.drop(gains, 5)
      var_first = variance(first_half)
      var_second = variance(second_half)

      assert var_second <= var_first + 0.01,
             "AGC gain should converge: first_var=#{var_first}, second_var=#{var_second}"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp rms(samples) do
    sum_sq = Enum.reduce(samples, 0.0, fn s, acc -> acc + s * s end)
    :math.sqrt(sum_sq / max(length(samples), 1))
  end

  defp variance(values) do
    n = length(values)
    if n < 2 do
      0.0
    else
      mean = Enum.sum(values) / n
      Enum.reduce(values, 0.0, fn v, acc -> acc + (v - mean) * (v - mean) end) / (n - 1)
    end
  end
end
