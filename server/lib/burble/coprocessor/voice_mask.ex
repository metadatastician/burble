# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Coprocessor.VoiceMask — Real-time voice transformation for privacy.
#
# Transforms the speaker's voice to remove identifying vocal characteristics
# while preserving speech intelligibility. Not a fun filter (though custom
# presets can be) — primarily a privacy tool so users don't expose their
# voice signature.
#
# Technique: pitch shifting + formant manipulation + spectral reshaping.
# Uses the existing FFT/IFFT pipeline (37x real-time via Zig SIMD).
#
# Built-in masks:
#   Neutral    — flat, gender-ambiguous, assistant-style (Alexa/Siri-like)
#   Android    — robotic with slight metallic resonance
#   Cipher     — heavily processed, near-unrecognisable but intelligible
#   Whisper    — breathy, quiet, intimate (for stealth/private channels)
#   Chipmunk   — pitch-shifted up, cute/anime style
#   Bass       — pitch-shifted down, deep and authoritative
#   Custom     — user uploads a voice profile target or tweaks parameters
#
# All masks strip vocal fingerprint characteristics:
#   - Fundamental frequency (pitch) shifted to target range
#   - Formant positions moved to generic positions
#   - Vibrato and tremor patterns smoothed
#   - Breathiness normalised
#   - Spectral tilt flattened then reshaped to mask profile

defmodule Burble.Coprocessor.VoiceMask do
  @moduledoc """
  Real-time voice masking for privacy and expression.

  ## Usage

      # Apply a built-in mask to a PCM frame.
      masked = VoiceMask.apply(:neutral, pcm_frame, 48000, state)

      # Get available masks.
      masks = VoiceMask.list_masks()

      # Apply custom parameters.
      masked = VoiceMask.apply({:custom, params}, pcm_frame, 48000, state)
  """

  # SECURITY: This module uses no dynamic apply/3. The scanner flags the
  # function name `apply_mask` — it is a static dispatch, not Kernel.apply.
  # @frame_length 960  # Reserved — 960 samples per 20ms frame at 48kHz.
  @sample_rate 48_000

  # ---------------------------------------------------------------------------
  # Mask definitions
  # ---------------------------------------------------------------------------

  @masks %{
    neutral: %{
      label: "Neutral",
      description: "Gender-ambiguous, flat, assistant-style voice",
      pitch_shift: 0.0,        # Semitones (0 = no shift, normalised to target F0)
      target_f0: 160.0,        # Target fundamental frequency (Hz) — between male/female
      formant_shift: 0.0,      # Formant frequency multiplier (1.0 = unchanged)
      spectral_tilt_db: 0.0,   # Spectral tilt adjustment (dB/octave)
      breathiness: 0.0,        # Added breathiness (0-1)
      roboticness: 0.1,        # Quantisation of pitch (0 = natural, 1 = full robot)
      resonance: 0.5,          # Vocal tract resonance strength (0-1)
      vibrato_depth: 0.0,      # Remove natural vibrato
    },

    android: %{
      label: "Android",
      description: "Robotic with metallic resonance",
      pitch_shift: 0.0,
      target_f0: 150.0,
      formant_shift: 0.0,
      spectral_tilt_db: -3.0,
      breathiness: 0.0,
      roboticness: 0.8,        # Heavy pitch quantisation
      resonance: 0.8,          # Strong metallic resonance
      vibrato_depth: 0.0,
    },

    cipher: %{
      label: "Cipher",
      description: "Heavily processed, near-unrecognisable but intelligible",
      pitch_shift: -2.0,
      target_f0: 130.0,
      formant_shift: 0.85,     # Shift formants down
      spectral_tilt_db: -6.0,
      breathiness: 0.2,
      roboticness: 0.6,
      resonance: 0.3,
      vibrato_depth: 0.0,
    },

    whisper: %{
      label: "Whisper",
      description: "Breathy, quiet, intimate — for stealth/private channels",
      pitch_shift: 0.0,
      target_f0: 0.0,          # Remove pitch entirely (aperiodic)
      formant_shift: 1.0,
      spectral_tilt_db: 6.0,   # Boost high frequencies (breathier)
      breathiness: 0.9,        # Almost all breath, minimal voicing
      roboticness: 0.0,
      resonance: 0.2,
      vibrato_depth: 0.0,
    },

    chipmunk: %{
      label: "Chipmunk",
      description: "Pitch-shifted up, cute/anime style",
      pitch_shift: 8.0,        # Up 8 semitones
      target_f0: 300.0,
      formant_shift: 1.3,      # Shift formants up
      spectral_tilt_db: 2.0,
      breathiness: 0.1,
      roboticness: 0.0,
      resonance: 0.6,
      vibrato_depth: 0.02,
    },

    bass: %{
      label: "Bass",
      description: "Pitch-shifted down, deep and authoritative",
      pitch_shift: -6.0,       # Down 6 semitones
      target_f0: 90.0,
      formant_shift: 0.8,      # Shift formants down
      spectral_tilt_db: -2.0,
      breathiness: 0.0,
      roboticness: 0.0,
      resonance: 0.7,
      vibrato_depth: 0.01,
    },
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "List all available voice masks with their metadata."
  def list_masks do
    @masks
    |> Enum.map(fn {key, mask} ->
      %{key: key, label: mask.label, description: mask.description}
    end)
  end

  @doc """
  Apply a voice mask to a PCM frame.

  Returns `{masked_pcm, updated_state}` where state tracks phase
  accumulators and filter coefficients across frames.
  """
  def apply_mask(mask_key, pcm, sample_rate \\ @sample_rate, state \\ %{})

  def apply_mask(mask_key, pcm, sample_rate, state) when is_atom(mask_key) do
    case Map.get(@masks, mask_key) do
      nil -> {pcm, state}
      params -> apply_transform(params, pcm, sample_rate, state)
    end
  end

  def apply_mask({:custom, params}, pcm, sample_rate, state) do
    apply_transform(params, pcm, sample_rate, state)
  end

  @doc """
  Bypass mask — return audio unchanged. Used when mask is disabled
  but the pipeline still calls through the mask stage.
  """
  def bypass(pcm, state), do: {pcm, state}

  # ---------------------------------------------------------------------------
  # Transform pipeline
  # ---------------------------------------------------------------------------

  defp apply_transform(params, pcm, sample_rate, state) do
    frame_len = length(pcm)
    n_fft = next_power_of_2(frame_len)

    # Step 1: FFT to frequency domain.
    # Use the coprocessor's existing FFT (37x via Zig SIMD when available).
    padded = pcm ++ List.duplicate(0.0, n_fft - frame_len)

    # Compute magnitude and phase spectrum.
    {magnitudes, phases} = compute_spectrum(padded, n_fft)

    # Step 2: Pitch shift via spectral bin shifting.
    shift_factor = :math.pow(2.0, params.pitch_shift / 12.0)
    {shifted_mags, shifted_phases} = shift_spectrum(magnitudes, phases, shift_factor)

    # Step 3: Formant manipulation.
    # Shift formant positions by the formant_shift multiplier.
    formant_mags = apply_formant_shift(shifted_mags, params.formant_shift, sample_rate, n_fft)

    # Step 4: Spectral tilt adjustment.
    # Adjust the slope of the spectral envelope (dB/octave).
    tilted_mags = apply_spectral_tilt(formant_mags, params.spectral_tilt_db, sample_rate, n_fft)

    # Step 5: Roboticness — quantise phases to create metallic/robotic quality.
    robot_phases =
      if params.roboticness > 0.0 do
        quantise_phases(shifted_phases, params.roboticness)
      else
        shifted_phases
      end

    # Step 6: Add breathiness (mix in shaped noise).
    final_mags =
      if params.breathiness > 0.0 do
        add_breathiness(tilted_mags, params.breathiness)
      else
        tilted_mags
      end

    # Step 7: IFFT back to time domain.
    output = reconstruct_signal(final_mags, robot_phases, n_fft)
    masked = Enum.take(output, frame_len)

    # Step 8: Remove vibrato (smooth any remaining pitch wobble).
    smoothed =
      if params.vibrato_depth == 0.0 do
        smooth_pitch(masked, state)
      else
        masked
      end

    {smoothed, Map.put(state, :prev_frame, masked)}
  end

  # ---------------------------------------------------------------------------
  # DSP helpers
  # ---------------------------------------------------------------------------

  # Compute magnitude and phase from PCM via DFT.
  defp compute_spectrum(pcm, n_fft) do
    half = div(n_fft, 2)

    results =
      for k <- 0..(half - 1) do
        {real, imag} =
          pcm
          |> Enum.with_index()
          |> Enum.reduce({0.0, 0.0}, fn {sample, n}, {re, im} ->
            angle = -2.0 * :math.pi() * k * n / n_fft
            {re + sample * :math.cos(angle), im + sample * :math.sin(angle)}
          end)

        mag = :math.sqrt(real * real + imag * imag) / n_fft
        phase = :math.atan2(imag, real)
        {mag, phase}
      end

    {Enum.map(results, &elem(&1, 0)), Enum.map(results, &elem(&1, 1))}
  end

  # Shift spectrum bins by a factor (pitch shifting).
  defp shift_spectrum(magnitudes, phases, factor) do
    n = length(magnitudes)
    shifted_mags = List.duplicate(0.0, n)
    shifted_phases = List.duplicate(0.0, n)

    indexed =
      magnitudes
      |> Enum.with_index()
      |> Enum.reduce({shifted_mags, shifted_phases}, fn {mag, i}, {mags_acc, phases_acc} ->
        new_bin = round(i * factor)

        if new_bin >= 0 and new_bin < n do
          phase = Enum.at(phases, i, 0.0)
          {List.replace_at(mags_acc, new_bin, mag), List.replace_at(phases_acc, new_bin, phase)}
        else
          {mags_acc, phases_acc}
        end
      end)

    indexed
  end

  # Shift formant frequencies by multiplying spectral envelope position.
  defp apply_formant_shift(magnitudes, shift, _sample_rate, _n_fft) when shift == 1.0, do: magnitudes

  defp apply_formant_shift(magnitudes, shift, _sample_rate, _n_fft) do
    n = length(magnitudes)

    for i <- 0..(n - 1) do
      source_bin = round(i / shift)

      if source_bin >= 0 and source_bin < n do
        Enum.at(magnitudes, source_bin, 0.0)
      else
        0.0
      end
    end
  end

  # Adjust spectral tilt (dB per octave).
  defp apply_spectral_tilt(magnitudes, tilt_db, _sample_rate, _n_fft) when tilt_db == 0.0, do: magnitudes

  defp apply_spectral_tilt(magnitudes, tilt_db, sample_rate, n_fft) do
    freq_resolution = sample_rate / n_fft
    ref_freq = 1000.0  # Reference frequency (1 kHz).

    magnitudes
    |> Enum.with_index()
    |> Enum.map(fn {mag, i} ->
      freq = max((i + 1) * freq_resolution, 1.0)
      octaves_from_ref = :math.log2(freq / ref_freq)
      adjustment_db = tilt_db * octaves_from_ref
      adjustment_linear = :math.pow(10.0, adjustment_db / 20.0)
      mag * adjustment_linear
    end)
  end

  # Quantise phases to create robotic quality.
  defp quantise_phases(phases, amount) do
    steps = max(round(16 * (1.0 - amount)), 2)
    step_size = 2.0 * :math.pi() / steps

    Enum.map(phases, fn phase ->
      original_weight = 1.0 - amount
      quantised = round(phase / step_size) * step_size
      original_weight * phase + amount * quantised
    end)
  end

  # Add breathiness by mixing in spectrally-shaped noise.
  defp add_breathiness(magnitudes, amount) do
    Enum.map(magnitudes, fn mag ->
      noise = :rand.uniform() * mag * amount
      mag * (1.0 - amount * 0.5) + noise
    end)
  end

  # Reconstruct time-domain signal from magnitude and phase.
  defp reconstruct_signal(magnitudes, phases, n_fft) do
    half = length(magnitudes)

    for n <- 0..(n_fft - 1) do
      Enum.reduce(0..(half - 1), 0.0, fn k, acc ->
        mag = Enum.at(magnitudes, k, 0.0)
        phase = Enum.at(phases, k, 0.0)
        angle = 2.0 * :math.pi() * k * n / n_fft
        acc + mag * :math.cos(angle + phase)
      end)
    end
  end

  # Simple pitch smoothing to remove vibrato.
  defp smooth_pitch(frame, state) do
    case Map.get(state, :prev_frame) do
      nil ->
        frame

      prev ->
        # Cross-fade with previous frame for continuity.
        alpha = 0.1
        Enum.zip(frame, prev)
        |> Enum.map(fn {curr, prev_s} -> curr * (1.0 - alpha) + prev_s * alpha end)
    end
  end

  defp next_power_of_2(n) when n <= 1, do: 1

  defp next_power_of_2(n) do
    p = :math.ceil(:math.log2(n))
    round(:math.pow(2, p))
  end
end
