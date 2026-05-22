# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Coprocessor.SignalScience — Advanced DSP algorithms for the
# coprocessor system.
#
# All algorithms are implemented as pure Elixir (reference backend).
# They follow the same pattern as existing SmartBackend functions:
# take audio samples as a list of floats, return processed samples.
#
# Algorithms:
#   1. Wiener Filter — spectral noise reduction with adaptive estimation
#   2. De-reverberation — spectral subtraction for late reverb removal
#   3. Spectral PLC — packet loss concealment via spectral interpolation
#   4. Per-User VAD Learning — adaptive VAD thresholds per speaker
#
# These are DSP-heavy operations suitable for Zig acceleration in Phase 2.
# The Elixir implementations serve as reference and fallback.

defmodule Burble.Coprocessor.SignalScience do
  @moduledoc """
  Advanced signal science algorithms for Burble's audio coprocessor.

  Provides four advanced DSP capabilities beyond the basic audio kernel:

  ## Wiener Filter
  Spectral noise reduction. Estimates noise spectrum during silence,
  computes per-bin Wiener gain, and applies to each frame. Adapts to
  changing noise conditions over time.

  ## De-reverberation
  Late reverberation removal via spectral subtraction. Estimates the
  late reverb spectrum from recent frames and subtracts it, reducing
  room echo/reverb without affecting direct speech.

  ## Spectral Packet Loss Concealment (PLC)
  When an audio frame is lost (network packet drop), generates a
  synthetic replacement by interpolating the spectrum between the last
  good frame and silence. Preserves phase continuity for natural sound.

  ## Per-User VAD Learning
  Learns each user's speech characteristics over time (typical energy,
  spectral shape) and adapts VAD thresholds per user. Reduces false
  positives for quiet speakers and false negatives for loud typists.

  All functions operate on lists of floats (normalised -1.0..1.0) and
  return processed sample lists, consistent with the Backend behaviour.
  """

  # ---------------------------------------------------------------------------
  # Wiener Filter
  # ---------------------------------------------------------------------------

  @doc """
  Apply a Wiener filter for spectral noise reduction.

  Estimates the noise power spectrum during non-speech frames and
  computes a per-frequency-bin gain (Wiener gain) to suppress noise
  while preserving speech.

  ## Parameters

    * `pcm` — Audio samples as a list of floats (-1.0..1.0)
    * `sample_rate` — Sample rate in Hz (typically 48000)
    * `state` — Wiener filter state (pass empty map for initial frame)

  ## State fields

    * `:noise_psd` — Estimated noise power spectral density (list of floats)
    * `:frame_count` — Number of frames processed so far
    * `:alpha` — Noise PSD smoothing factor (0.0-1.0, higher = slower adaptation)

  ## Returns

    `{filtered_pcm, updated_state}` where filtered_pcm has reduced noise
    and updated_state should be passed to the next call.

  ## Algorithm

  1. Compute magnitude spectrum via FFT
  2. Compute power spectral density (PSD) = magnitude^2
  3. If non-speech frame (low energy), update noise PSD estimate
  4. Compute Wiener gain per bin: G(k) = max(0, 1 - noise_psd(k) / signal_psd(k))
  5. Apply gain in frequency domain
  6. IFFT back to time domain
  """
  @spec wiener_filter([float()], pos_integer(), map()) :: {[float()], map()}
  def wiener_filter(pcm, _sample_rate, state) do
    frame_len = length(pcm)
    # Use next power of 2 for FFT.
    fft_size = next_power_of_2(frame_len)

    # Zero-pad to FFT size.
    padded = pcm ++ List.duplicate(0.0, fft_size - frame_len)

    # Compute FFT (complex spectrum).
    spectrum = fft(padded, fft_size)

    # Compute power spectral density: PSD(k) = |X(k)|^2.
    psd =
      Enum.map(spectrum, fn {re, im} ->
        re * re + im * im
      end)

    # Initialize or retrieve noise PSD estimate.
    noise_psd = Map.get(state, :noise_psd, List.duplicate(0.0, fft_size))
    frame_count = Map.get(state, :frame_count, 0)
    alpha = Map.get(state, :alpha, 0.98)

    # Compute frame energy to decide if this is a noise-only frame.
    frame_energy = Enum.sum(psd) / max(fft_size, 1)

    # Adaptive noise PSD estimation.
    # During the first 10 frames, always update (assume noise).
    # After that, update only during low-energy (non-speech) frames.
    noise_threshold = Enum.sum(noise_psd) / max(fft_size, 1) * 2.0

    is_noise_frame = frame_count < 10 or frame_energy < max(noise_threshold, 1.0e-10)

    updated_noise_psd =
      if is_noise_frame do
        # Exponential moving average of noise PSD.
        Enum.zip(noise_psd, psd)
        |> Enum.map(fn {n, s} ->
          if frame_count == 0 do
            s  # First frame: initialise with signal PSD.
          else
            alpha * n + (1.0 - alpha) * s
          end
        end)
      else
        noise_psd
      end

    # Compute Wiener gain per frequency bin.
    # G(k) = max(gain_floor, 1 - noise_psd(k) / signal_psd(k))
    # Gain floor prevents musical noise artefacts.
    gain_floor = 0.1

    wiener_gains =
      Enum.zip(updated_noise_psd, psd)
      |> Enum.map(fn {n_psd, s_psd} ->
        if s_psd > 1.0e-12 do
          max(gain_floor, 1.0 - n_psd / s_psd)
        else
          gain_floor
        end
      end)

    # Apply Wiener gains in frequency domain.
    filtered_spectrum =
      Enum.zip(spectrum, wiener_gains)
      |> Enum.map(fn {{re, im}, g} ->
        {re * g, im * g}
      end)

    # IFFT back to time domain.
    filtered_pcm = ifft(filtered_spectrum, fft_size)

    # Take only the original frame length.
    output = Enum.take(filtered_pcm, frame_len)

    new_state = %{
      noise_psd: updated_noise_psd,
      frame_count: frame_count + 1,
      alpha: alpha
    }

    {output, new_state}
  end

  # ---------------------------------------------------------------------------
  # De-reverberation
  # ---------------------------------------------------------------------------

  @doc """
  Apply de-reverberation via spectral subtraction.

  Estimates the late reverberation spectrum from recent frames and
  subtracts it from the current frame's spectrum, reducing room echo.

  ## Parameters

    * `pcm` — Audio samples as a list of floats (-1.0..1.0)
    * `sample_rate` — Sample rate in Hz
    * `state` — De-reverb state (pass empty map for initial frame)

  ## State fields

    * `:prev_spectra` — Ring buffer of recent magnitude spectra
    * `:reverb_time_ms` — Estimated reverb time in milliseconds (configurable)
    * `:subtraction_factor` — How aggressively to subtract reverb (0.0-2.0)
    * `:frame_duration_ms` — Frame duration in milliseconds

  ## Returns

    `{dereverberated_pcm, updated_state}`

  ## Algorithm

  1. Compute magnitude spectrum of current frame
  2. Estimate late reverb spectrum from frames T_reverb ago
  3. Subtract scaled reverb estimate from current magnitude
  4. Reconstruct using original phase (magnitude-only modification)
  5. IFFT to time domain
  """
  @spec dereverberate([float()], pos_integer(), map()) :: {[float()], map()}
  def dereverberate(pcm, _sample_rate, state) do
    frame_len = length(pcm)
    fft_size = next_power_of_2(frame_len)

    # Configuration with defaults.
    reverb_time_ms = Map.get(state, :reverb_time_ms, 200.0)
    subtraction_factor = Map.get(state, :subtraction_factor, 1.0)
    frame_duration_ms = Map.get(state, :frame_duration_ms, 20.0)

    # How many frames back to look for reverb estimation.
    reverb_frames = max(1, round(reverb_time_ms / frame_duration_ms))

    # Zero-pad and FFT.
    padded = pcm ++ List.duplicate(0.0, fft_size - frame_len)
    spectrum = fft(padded, fft_size)

    # Separate magnitude and phase.
    magnitudes = Enum.map(spectrum, fn {re, im} -> :math.sqrt(re * re + im * im) end)

    phases =
      Enum.map(spectrum, fn {re, im} ->
        :math.atan2(im, re)
      end)

    # Retrieve the ring buffer of previous magnitude spectra.
    prev_spectra = Map.get(state, :prev_spectra, [])

    # Estimate late reverberation from the frame that was reverb_frames ago.
    reverb_estimate =
      if length(prev_spectra) >= reverb_frames do
        # The frame from reverb_frames ago contributes to current reverb.
        Enum.at(prev_spectra, reverb_frames - 1)
      else
        # Not enough history — no reverb estimate yet.
        List.duplicate(0.0, fft_size)
      end

    # Spectral subtraction: subtract scaled reverb estimate from current magnitude.
    # Floor at 0 to avoid negative magnitudes (which cause phase inversion artefacts).
    spectral_floor = 0.01

    dereverberated_magnitudes =
      Enum.zip(magnitudes, reverb_estimate)
      |> Enum.map(fn {mag, reverb} ->
        max(spectral_floor, mag - subtraction_factor * reverb)
      end)

    # Reconstruct complex spectrum from modified magnitudes and original phases.
    filtered_spectrum =
      Enum.zip(dereverberated_magnitudes, phases)
      |> Enum.map(fn {mag, phase} ->
        {mag * :math.cos(phase), mag * :math.sin(phase)}
      end)

    # IFFT back to time domain.
    filtered_pcm = ifft(filtered_spectrum, fft_size)
    output = Enum.take(filtered_pcm, frame_len)

    # Update ring buffer (keep last reverb_frames + some margin).
    max_history = reverb_frames + 5
    updated_spectra = [magnitudes | Enum.take(prev_spectra, max_history - 1)]

    new_state = %{
      prev_spectra: updated_spectra,
      reverb_time_ms: reverb_time_ms,
      subtraction_factor: subtraction_factor,
      frame_duration_ms: frame_duration_ms
    }

    {output, new_state}
  end

  # ---------------------------------------------------------------------------
  # Spectral Packet Loss Concealment (PLC)
  # ---------------------------------------------------------------------------

  @doc """
  Generate a concealment frame when a packet is lost.

  Uses spectral interpolation between the last good frame and silence
  to produce a natural-sounding replacement that avoids clicks and
  maintains phase continuity.

  ## Parameters

    * `state` — PLC state containing recent frame history

  ## State fields

    * `:last_good_spectrum` — Complex FFT of last successfully received frame
    * `:last_good_pcm` — PCM samples of last good frame
    * `:consecutive_losses` — Number of consecutive lost frames
    * `:fade_rate` — How quickly to fade to silence per lost frame (0.0-1.0)
    * `:frame_length` — Expected frame length in samples

  ## Returns

    `{concealment_pcm, updated_state}`

  ## Algorithm

  1. If we have a last good frame, start from its spectrum
  2. Apply progressive fade based on number of consecutive losses
  3. Maintain phase continuity by advancing phase at the same rate
  4. After too many consecutive losses, output silence
  """
  @spec spectral_plc(map()) :: {[float()], map()}
  def spectral_plc(state) do
    last_spectrum = Map.get(state, :last_good_spectrum, [])
    last_pcm = Map.get(state, :last_good_pcm, [])
    consecutive_losses = Map.get(state, :consecutive_losses, 0)
    fade_rate = Map.get(state, :fade_rate, 0.8)
    frame_length = Map.get(state, :frame_length, 960)

    if last_spectrum == [] or consecutive_losses > 10 do
      # No history or too many consecutive losses — output silence.
      silence = List.duplicate(0.0, frame_length)

      new_state = %{
        state
        | consecutive_losses: consecutive_losses + 1
      }

      {silence, new_state}
    else
      # Compute fade factor: decreases with each consecutive loss.
      # fade_factor = fade_rate ^ consecutive_losses
      fade_factor = :math.pow(fade_rate, consecutive_losses + 1)

      # Apply fade to the last good spectrum's magnitudes while
      # advancing phase to maintain continuity.
      fft_size = length(last_spectrum)

      concealment_spectrum =
        last_spectrum
        |> Enum.with_index()
        |> Enum.map(fn {{re, im}, k} ->
          magnitude = :math.sqrt(re * re + im * im) * fade_factor
          phase = :math.atan2(im, re)

          # Advance phase by the expected phase increment for this bin.
          # Phase increment per frame ≈ 2π * k * frame_length / fft_size.
          phase_advance = 2.0 * :math.pi() * k * frame_length / max(fft_size, 1)
          new_phase = phase + phase_advance * (consecutive_losses + 1)

          {magnitude * :math.cos(new_phase), magnitude * :math.sin(new_phase)}
        end)

      # IFFT to get time-domain concealment frame.
      concealment_pcm = ifft(concealment_spectrum, fft_size)
      output = Enum.take(concealment_pcm, frame_length)

      # Apply overlap-add with the tail of the last good frame for smooth transition.
      # Use a short crossfade (10% of frame) at the boundary.
      crossfade_len = max(div(frame_length, 10), 1)

      output =
        if length(last_pcm) >= frame_length do
          output
          |> Enum.with_index()
          |> Enum.map(fn {sample, idx} ->
            if idx < crossfade_len do
              # Crossfade region: blend with end of last good frame.
              alpha = idx / crossfade_len
              last_sample = Enum.at(last_pcm, frame_length - crossfade_len + idx, 0.0)
              sample * alpha + last_sample * (1.0 - alpha)
            else
              sample
            end
          end)
        else
          output
        end

      new_state = %{
        state
        | consecutive_losses: consecutive_losses + 1,
          last_good_spectrum: concealment_spectrum
      }

      {output, new_state}
    end
  end

  @doc """
  Update PLC state with a successfully received frame.

  Call this for every good frame to keep the PLC history current.

  ## Parameters

    * `pcm` — Successfully received audio samples
    * `state` — Current PLC state

  ## Returns

    Updated PLC state with reset consecutive_losses counter.
  """
  @spec plc_receive_good_frame([float()], map()) :: map()
  def plc_receive_good_frame(pcm, state) do
    frame_length = length(pcm)
    fft_size = next_power_of_2(frame_length)

    # Compute and store the spectrum for future concealment.
    padded = pcm ++ List.duplicate(0.0, fft_size - frame_length)
    spectrum = fft(padded, fft_size)

    %{
      state
      | last_good_spectrum: spectrum,
        last_good_pcm: pcm,
        consecutive_losses: 0,
        frame_length: frame_length
    }
    |> Map.put_new(:fade_rate, 0.8)
  end

  # ---------------------------------------------------------------------------
  # Per-User VAD Learning
  # ---------------------------------------------------------------------------

  @doc """
  Perform voice activity detection with per-user adaptive learning.

  Tracks each user's speech characteristics over time and adapts
  VAD thresholds to their specific voice. This reduces false positives
  for quiet speakers and false negatives for users with noisy backgrounds.

  ## Parameters

    * `pcm` — Audio samples from this user
    * `user_id` — Unique identifier for the speaker
    * `sample_rate` — Sample rate in Hz
    * `state` — Global VAD learning state (map of user_id => learned params)

  ## Per-user learned parameters (in state[user_id])

    * `:speech_energy_mean` — Running mean of energy during speech frames
    * `:speech_energy_var` — Running variance of speech energy
    * `:noise_energy_mean` — Running mean of energy during noise frames
    * `:spectral_centroid_mean` — Typical spectral centroid during speech
    * `:energy_threshold` — Adapted energy threshold for this user
    * `:frame_count` — Total frames processed for this user
    * `:speech_frame_count` — Number of frames classified as speech

  ## Returns

    `{is_speech, confidence, updated_state}` where:
    - `is_speech` — boolean indicating voice activity
    - `confidence` — 0.0-1.0 confidence in the decision
    - `updated_state` — pass back to subsequent calls
  """
  @spec per_user_vad([float()], String.t(), pos_integer(), map()) ::
          {boolean(), float(), map()}
  def per_user_vad(pcm, user_id, sample_rate, state) do
    # Retrieve or initialise this user's learned parameters.
    user_params = Map.get(state, user_id, default_user_params())

    frame_len = length(pcm)

    # Feature extraction.
    # 1. Frame energy (RMS).
    sum_sq = Enum.reduce(pcm, 0.0, fn s, acc -> acc + s * s end)
    rms = :math.sqrt(sum_sq / max(frame_len, 1))

    # 2. Spectral centroid.
    n_bins = min(div(frame_len, 2), 128)
    magnitudes = compute_magnitude_spectrum_simple(pcm, n_bins)
    total_energy = Enum.sum(magnitudes)
    freq_resolution = sample_rate / (2.0 * max(n_bins, 1))

    spectral_centroid =
      if total_energy > 1.0e-12 do
        magnitudes
        |> Enum.with_index()
        |> Enum.reduce(0.0, fn {mag, i}, acc -> acc + mag * (i * freq_resolution) end)
        |> Kernel./(total_energy)
      else
        0.0
      end

    # 3. Spectral flatness.
    spectral_flatness = compute_spectral_flatness(magnitudes)

    # 4. Zero-crossing rate.
    zcr = compute_zcr(pcm)

    # Compute adaptive energy threshold based on learned parameters.
    energy_threshold = user_params.energy_threshold
    centroid_mean = user_params.spectral_centroid_mean

    # Multi-feature VAD decision.
    # Energy score: how far above the threshold is this frame?
    energy_score =
      if rms > energy_threshold * 1.5 do
        1.0
      else
        if rms > energy_threshold do
          (rms - energy_threshold) / max(energy_threshold * 0.5, 1.0e-10)
        else
          0.0
        end
      end

    # Spectral score: speech has lower flatness and centroid in speech band.
    flatness_score = if spectral_flatness < 0.6, do: 0.7, else: 0.2
    centroid_score =
      if spectral_centroid > 200.0 and spectral_centroid < 4500.0 do
        # Extra boost if centroid is near the user's learned speech centroid.
        centroid_distance = abs(spectral_centroid - centroid_mean)
        if centroid_distance < 500.0, do: 1.0, else: 0.6
      else
        0.1
      end

    # ZCR score: speech typically has moderate ZCR (0.05-0.3).
    zcr_score = if zcr > 0.05 and zcr < 0.35, do: 0.5, else: 0.2

    # Weighted decision.
    confidence =
      energy_score * 0.45 +
        flatness_score * 0.20 +
        centroid_score * 0.25 +
        zcr_score * 0.10

    # Clamp confidence to [0, 1].
    confidence = max(0.0, min(1.0, confidence))
    is_speech = confidence > 0.45

    # Update learned parameters.
    updated_params = update_user_params(user_params, rms, spectral_centroid, is_speech)

    # Store updated params back into global state.
    updated_state = Map.put(state, user_id, updated_params)

    {is_speech, confidence, updated_state}
  end

  @doc """
  Get the learned parameters for a specific user.

  Useful for diagnostics and debugging VAD behaviour.

  ## Parameters

    * `user_id` — The user to query
    * `state` — Global VAD learning state

  ## Returns

    The user's learned parameter map, or nil if not found.
  """
  @spec get_user_params(String.t(), map()) :: map() | nil
  def get_user_params(user_id, state) do
    Map.get(state, user_id)
  end

  @doc """
  Reset learned parameters for a specific user.

  Call this when a user's environment changes significantly
  (e.g., they switch microphones or rooms).

  ## Parameters

    * `user_id` — The user to reset
    * `state` — Global VAD learning state

  ## Returns

    Updated state with default parameters for this user.
  """
  @spec reset_user_params(String.t(), map()) :: map()
  def reset_user_params(user_id, state) do
    Map.put(state, user_id, default_user_params())
  end

  # ---------------------------------------------------------------------------
  # Private: Per-user VAD learning helpers
  # ---------------------------------------------------------------------------

  # Default parameters for a new user (conservative thresholds).
  defp default_user_params do
    %{
      speech_energy_mean: 0.05,
      speech_energy_var: 0.001,
      noise_energy_mean: 0.005,
      spectral_centroid_mean: 1500.0,
      energy_threshold: 0.01,
      frame_count: 0,
      speech_frame_count: 0
    }
  end

  # Update a user's learned parameters based on the current frame.
  defp update_user_params(params, rms, spectral_centroid, is_speech) do
    frame_count = params.frame_count + 1

    # Use exponential moving average for online learning.
    # Slower adaptation (higher alpha) as we collect more data.
    alpha = min(0.99, 0.9 + frame_count * 0.0001)

    if is_speech do
      # Update speech statistics.
      new_speech_energy = alpha * params.speech_energy_mean + (1.0 - alpha) * rms

      energy_diff = rms - params.speech_energy_mean
      new_speech_var = alpha * params.speech_energy_var + (1.0 - alpha) * energy_diff * energy_diff

      new_centroid = alpha * params.spectral_centroid_mean + (1.0 - alpha) * spectral_centroid

      # Adapt energy threshold: midpoint between noise and speech means,
      # biased slightly toward noise to catch quiet speech.
      new_threshold =
        params.noise_energy_mean + (new_speech_energy - params.noise_energy_mean) * 0.3

      %{
        params
        | speech_energy_mean: new_speech_energy,
          speech_energy_var: new_speech_var,
          spectral_centroid_mean: new_centroid,
          energy_threshold: max(new_threshold, 0.001),
          frame_count: frame_count,
          speech_frame_count: params.speech_frame_count + 1
      }
    else
      # Update noise statistics.
      new_noise_energy = alpha * params.noise_energy_mean + (1.0 - alpha) * rms

      # Re-adapt threshold when noise floor changes.
      new_threshold =
        new_noise_energy + (params.speech_energy_mean - new_noise_energy) * 0.3

      %{
        params
        | noise_energy_mean: new_noise_energy,
          energy_threshold: max(new_threshold, 0.001),
          frame_count: frame_count
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Private: DSP helpers
  # ---------------------------------------------------------------------------

  # Cooley-Tukey radix-2 DIT FFT. Input is a list of real floats.
  # Returns a list of {real, imaginary} complex tuples.
  defp fft(signal, size) when size <= 1 do
    Enum.map(signal, fn s -> {s, 0.0} end)
  end

  defp fft(signal, size) do
    half = div(size, 2)

    {evens, odds} =
      signal
      |> Enum.with_index()
      |> Enum.split_with(fn {_val, idx} -> rem(idx, 2) == 0 end)

    even_vals = Enum.map(evens, fn {v, _} -> v end)
    odd_vals = Enum.map(odds, fn {v, _} -> v end)

    fft_even = fft(even_vals, half)
    fft_odd = fft(odd_vals, half)

    Enum.map(0..(size - 1), fn k ->
      k_mod = rem(k, half)
      angle = -2.0 * :math.pi() * k / size
      {wr, wi} = {:math.cos(angle), :math.sin(angle)}

      {or_val, oi_val} = Enum.at(fft_odd, k_mod)
      {er, ei} = Enum.at(fft_even, k_mod)

      tr = wr * or_val - wi * oi_val
      ti = wr * oi_val + wi * or_val

      if k < half do
        {er + tr, ei + ti}
      else
        {er - tr, ei - ti}
      end
    end)
  end

  # Inverse FFT via conjugate trick: IFFT(X) = conj(FFT(conj(X))) / N.
  defp ifft(spectrum, size) do
    # Conjugate the input spectrum.
    conjugated = Enum.map(spectrum, fn {r, i} -> {r, -i} end)

    # Extract real parts for FFT (treating complex input as interleaved).
    # We need to FFT the complex conjugate, so we pass through the real FFT
    # by converting to real signal representation.
    real_parts = Enum.map(conjugated, fn {r, _i} -> r end)
    fft_result = fft(real_parts, size)

    # Take real parts and divide by N.
    Enum.map(fft_result, fn {r, _i} -> r / size end)
  end

  # Find the next power of 2 >= n.
  defp next_power_of_2(n) when n <= 1, do: 1

  defp next_power_of_2(n) do
    p = :math.ceil(:math.log(n) / :math.log(2)) |> trunc()
    trunc(:math.pow(2, p))
  end

  # Compute a simple magnitude spectrum via DFT (for small bin counts).
  defp compute_magnitude_spectrum_simple(pcm, n_bins) do
    frame_len = length(pcm)

    for k <- 0..(n_bins - 1) do
      {real, imag} =
        pcm
        |> Enum.with_index()
        |> Enum.reduce({0.0, 0.0}, fn {sample, n}, {re, im} ->
          angle = -2.0 * :math.pi() * k * n / frame_len
          {re + sample * :math.cos(angle), im + sample * :math.sin(angle)}
        end)

      :math.sqrt(real * real + imag * imag) / max(frame_len, 1)
    end
  end

  # Compute spectral flatness: geometric_mean(magnitudes) / arithmetic_mean(magnitudes).
  # Returns a value between 0 (tonal) and 1 (flat/noisy).
  defp compute_spectral_flatness([]), do: 1.0

  defp compute_spectral_flatness(magnitudes) do
    n = length(magnitudes)

    log_sum =
      Enum.reduce(magnitudes, 0.0, fn m, acc ->
        acc + :math.log(max(m, 1.0e-12))
      end)

    geo_mean = :math.exp(log_sum / max(n, 1))
    arith_mean = Enum.sum(magnitudes) / max(n, 1)

    if arith_mean > 1.0e-12, do: geo_mean / arith_mean, else: 1.0
  end

  # Compute zero-crossing rate.
  defp compute_zcr([]), do: 0.0
  defp compute_zcr([_]), do: 0.0

  defp compute_zcr(pcm) do
    crossings =
      pcm
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> (a >= 0 and b < 0) or (a < 0 and b >= 0) end)

    crossings / (length(pcm) - 1)
  end
end
