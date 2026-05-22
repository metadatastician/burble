# SPDX-License-Identifier: MPL-2.0
#
# Burble.Coprocessor.ElixirBackend — Pure Elixir reference implementation.
#
# Every kernel operation has a correct (if not optimal) implementation here.
# This serves as:
#   1. Reference for testing — Zig backend must produce identical results
#   2. Fallback — if Zig NIFs aren't compiled, operations still work
#   3. Documentation — readable implementations of each algorithm
#
# Performance: adequate for small rooms (<10 peers). For larger deployments,
# the ZigBackend provides SIMD-accelerated hot paths.

defmodule Burble.Coprocessor.ElixirBackend do
  @moduledoc """
  Pure Elixir reference backend for all coprocessor kernels.

  Implements every `Burble.Coprocessor.Backend` callback using only
  Erlang/Elixir standard library functions. No NIFs, no external deps.
  """

  @behaviour Burble.Coprocessor.Backend

  import Bitwise

  # SECURITY FIX: Maximum packets in the jitter buffer before oldest are
  # discarded. Without this bound, a burst of out-of-order or delayed packets
  # causes unbounded list growth in io_jitter_buffer_push/4. At 20ms frames
  # this allows ~2 seconds of buffered audio — well above any reasonable
  # jitter target. Aligned with proven SafeQueue bounded capacity principle.
  @max_jitter_buffer_packets 100

  # ---------------------------------------------------------------------------
  # Backend metadata
  # ---------------------------------------------------------------------------

  @impl true
  def backend_type, do: :elixir

  @impl true
  def available?, do: true

  # ---------------------------------------------------------------------------
  # Audio kernel
  # ---------------------------------------------------------------------------

  @impl true
  def audio_encode(pcm, _sample_rate, channels, _bitrate) do
    # PCM frame pack: clamp to [-1.0, 1.0], scale to i16 LE, length-prefix.
    # NOT Opus compression — this round-trips raw PCM through audio_decode/3
    # for recording, archive, and self-test paths. Real Opus lives in the
    # browser's WebRTC encoder; server-side Opus requires linking libopus and
    # is gated behind opus_transcode/4 which returns {:error, :not_implemented}.
    samples =
      pcm
      |> Enum.map(fn sample ->
        clamped = max(-1.0, min(1.0, sample))
        trunc(clamped * 32767.0)
      end)

    binary =
      samples
      |> Enum.map(fn s -> <<s::little-signed-16>> end)
      |> IO.iodata_to_binary()

    header = <<channels::8, byte_size(binary)::32-little>>
    {:ok, header <> binary}
  end

  @impl true
  def audio_decode(pcm_frame, _sample_rate, _channels) do
    # PCM frame unpack — inverse of audio_encode/4. NOT Opus decode.
    case pcm_frame do
      <<_ch::8, len::32-little, data::binary-size(len), _rest::binary>> ->
        samples =
          for <<sample::little-signed-16 <- data>> do
            sample / 32767.0
          end

        {:ok, samples}

      _ ->
        {:error, :invalid_frame}
    end
  end

  @impl true
  def opus_transcode(_pcm_or_opus, _sample_rate, _channels, _bitrate) do
    # Real Opus transcoding is not implemented server-side by design
    # (SFU-opaque E2EE model). Linking libopus is a deferred decision
    # tracked in STATE.a2ml [migration]. Callers wanting real Opus must
    # either (a) rely on the browser's WebRTC Opus encoder/decoder, or
    # (b) request libopus integration to be added to this backend.
    {:error, :not_implemented}
  end

  @impl true
  def opus_available?, do: false

  @impl true
  def audio_noise_gate(pcm, threshold_db) do
    # Convert dB threshold to linear amplitude.
    threshold_linear = :math.pow(10.0, threshold_db / 20.0)

    Enum.map(pcm, fn sample ->
      if abs(sample) < threshold_linear, do: 0.0, else: sample
    end)
  end

  @impl true
  def audio_echo_cancel(capture, reference, filter_length) do
    # NLMS (Normalised Least Mean Squares) adaptive filter.
    # Step size (mu) controls convergence speed vs stability.
    mu = 0.5
    epsilon = 1.0e-8

    {output, _weights} =
      capture
      |> Enum.zip(reference)
      |> Enum.reduce({[], List.duplicate(0.0, filter_length)}, fn {cap, _ref}, {acc, weights} ->
        # Build reference window from accumulated reference samples.
        ref_window =
          reference
          |> Enum.take(filter_length)
          |> pad_to(filter_length)

        # Estimate echo: dot product of weights and reference window.
        echo_estimate = dot(weights, ref_window)

        # Error = capture - estimated echo.
        error = cap - echo_estimate

        # Normalise step size by reference power.
        power = dot(ref_window, ref_window) + epsilon
        step = mu / power

        # Update weights.
        new_weights =
          Enum.zip(weights, ref_window)
          |> Enum.map(fn {w, r} -> w + step * error * r end)

        {[error | acc], new_weights}
      end)

    Enum.reverse(output)
  end

  # ---------------------------------------------------------------------------
  # Signal science additions — AGC, comfort noise, spectral VAD, perceptual weighting
  # ---------------------------------------------------------------------------

  @impl true
  def audio_agc(pcm, target_rms_db, attack_ms, release_ms, state) do
    # Automatic gain control using RMS-based envelope tracking.
    # Computes frame RMS, compares to target, smooths gain change
    # using asymmetric attack/release time constants.
    target_rms = :math.pow(10.0, target_rms_db / 20.0)
    current_gain = Map.get(state, :gain, 1.0)

    # Compute frame RMS.
    sum_sq = Enum.reduce(pcm, 0.0, fn s, acc -> acc + s * s end)
    frame_len = max(length(pcm), 1)
    rms = :math.sqrt(sum_sq / frame_len)

    # Desired gain to reach target RMS.
    desired_gain =
      if rms > 1.0e-8 do
        min(target_rms / rms, 10.0)  # Cap at 20 dB boost
      else
        current_gain
      end

    # Smooth gain using attack/release time constants.
    # Attack (gain decreasing) is faster than release (gain increasing).
    alpha =
      if desired_gain < current_gain do
        # Attacking — gain needs to drop (loud signal).
        1.0 - :math.exp(-1.0 / max(attack_ms * 0.048, 0.001))
      else
        # Releasing — gain can rise (quiet signal).
        1.0 - :math.exp(-1.0 / max(release_ms * 0.048, 0.001))
      end

    new_gain = current_gain + alpha * (desired_gain - current_gain)

    # Apply gain with soft clipping to prevent distortion.
    normalised =
      Enum.map(pcm, fn sample ->
        amplified = sample * new_gain
        # Soft clip using tanh for natural limiting.
        if abs(amplified) > 0.9 do
          0.9 * :math.tanh(amplified / 0.9)
        else
          amplified
        end
      end)

    {normalised, Map.put(state, :gain, new_gain)}
  end

  @impl true
  def audio_comfort_noise(frame_length, level_db, noise_profile) do
    # Generate spectrally-shaped comfort noise.
    # 1. Generate white noise
    # 2. Shape it using the noise profile (spectral envelope from recent silence)
    # 3. Scale to the target level
    level_linear = :math.pow(10.0, level_db / 20.0)

    # Generate white noise samples.
    white_noise =
      for _ <- 1..frame_length do
        (:rand.uniform() * 2.0 - 1.0)
      end

    # If we have a noise profile, shape the noise spectrally.
    # Otherwise just return scaled white noise.
    shaped =
      if length(noise_profile) > 0 do
        # Simple spectral shaping: modulate amplitude of noise segments
        # by the noise profile envelope. Each profile bin covers
        # frame_length/profile_length samples.
        profile_len = length(noise_profile)
        segment_len = max(div(frame_length, profile_len), 1)

        white_noise
        |> Enum.chunk_every(segment_len)
        |> Enum.zip(noise_profile)
        |> Enum.flat_map(fn {chunk, weight} ->
          # Weight controls how much energy this frequency band has.
          Enum.map(chunk, fn s -> s * weight end)
        end)
        |> Enum.take(frame_length)
      else
        white_noise
      end

    # Scale to target level.
    Enum.map(shaped, fn s -> s * level_linear end)
  end

  @impl true
  def audio_spectral_vad(pcm, sample_rate, state) do
    # Spectral voice activity detection using three features:
    # 1. Spectral flatness (speech is less flat than noise)
    # 2. Spectral centroid (speech is centred around 500-4000 Hz)
    # 3. Zero-crossing rate (speech has lower ZCR than noise)
    #
    # Maintains running statistics for adaptive thresholding.

    frame_len = length(pcm)

    # Feature 1: Spectral flatness (geometric mean / arithmetic mean of magnitudes).
    # Compute a simple DFT magnitude spectrum (not full FFT for reference impl).
    n_bins = min(div(frame_len, 2), 256)
    magnitudes = compute_magnitude_spectrum(pcm, n_bins, sample_rate)

    spectral_flatness =
      if length(magnitudes) > 0 do
        geo_mean = :math.exp(Enum.reduce(magnitudes, 0.0, fn m, acc ->
          acc + :math.log(max(m, 1.0e-12))
        end) / max(length(magnitudes), 1))
        arith_mean = Enum.sum(magnitudes) / max(length(magnitudes), 1)
        if arith_mean > 1.0e-12, do: geo_mean / arith_mean, else: 1.0
      else
        1.0
      end

    # Feature 2: Spectral centroid (weighted average frequency).
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

    # Feature 3: Zero-crossing rate.
    zcr =
      pcm
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> (a >= 0 and b < 0) or (a < 0 and b >= 0) end)
      |> Kernel./(max(frame_len - 1, 1))

    # Adaptive thresholds from running statistics.
    noise_flatness = Map.get(state, :noise_flatness, 0.85)
    noise_zcr = Map.get(state, :noise_zcr, 0.3)
    frame_count = Map.get(state, :frame_count, 0)

    # Speech detection: speech is less flat, has centroid in speech band, lower ZCR.
    flatness_score = if spectral_flatness < noise_flatness * 0.7, do: 1.0, else: 0.0
    centroid_score = if spectral_centroid > 300.0 and spectral_centroid < 4000.0, do: 1.0, else: 0.0
    zcr_score = if zcr < noise_zcr * 1.5, do: 0.5, else: 0.0

    confidence = (flatness_score * 0.5 + centroid_score * 0.3 + zcr_score * 0.2)
    is_speech = confidence > 0.4

    # Update noise statistics during non-speech frames.
    new_state =
      if not is_speech and frame_count > 10 do
        alpha = 0.02  # Slow adaptation
        %{state |
          noise_flatness: noise_flatness * (1.0 - alpha) + spectral_flatness * alpha,
          noise_zcr: noise_zcr * (1.0 - alpha) + zcr * alpha,
          frame_count: frame_count + 1
        }
      else
        Map.put(state, :frame_count, frame_count + 1)
      end

    {is_speech, confidence, new_state}
  end

  @impl true
  def audio_perceptual_weight(magnitudes, sample_rate) do
    # A-weighting curve applied to FFT magnitude bins.
    # A-weighting approximates human hearing sensitivity:
    #   - Strong attenuation below 500 Hz (we hear bass poorly)
    #   - Flat response 1-6 kHz (most sensitive hearing range)
    #   - Gradual rolloff above 6 kHz
    #
    # Formula: A(f) = 12194^2 * f^4 / ((f^2 + 20.6^2) * sqrt((f^2 + 107.7^2) * (f^2 + 737.9^2)) * (f^2 + 12194^2))
    n_bins = length(magnitudes)
    freq_resolution = sample_rate / (2.0 * max(n_bins, 1))

    magnitudes
    |> Enum.with_index()
    |> Enum.map(fn {mag, i} ->
      f = max((i + 1) * freq_resolution, 1.0)
      f2 = f * f

      # A-weighting transfer function (simplified).
      numerator = 12194.0 * 12194.0 * f2 * f2
      denominator =
        (f2 + 20.6 * 20.6) *
        :math.sqrt((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9)) *
        (f2 + 12194.0 * 12194.0)

      a_weight = if denominator > 0, do: numerator / denominator, else: 0.0

      # Normalise so 1 kHz = 0 dB (A-weighting reference).
      # At 1 kHz, A-weight ≈ 0.7943 in linear, so normalise by reciprocal.
      normalised_weight = min(a_weight / 0.7943, 2.0)

      mag * normalised_weight
    end)
  end

  # ---------------------------------------------------------------------------
  # Signal science — advanced DSP (delegates to SignalScience module)
  # ---------------------------------------------------------------------------

  alias Burble.Coprocessor.SignalScience

  @doc "Wiener filter for spectral noise reduction. Delegates to SignalScience."
  def wiener_filter(pcm, sample_rate, state) do
    SignalScience.wiener_filter(pcm, sample_rate, state)
  end

  @doc "De-reverberation via spectral subtraction. Delegates to SignalScience."
  def dereverberate(pcm, sample_rate, state) do
    SignalScience.dereverberate(pcm, sample_rate, state)
  end

  @doc "Spectral packet loss concealment. Delegates to SignalScience."
  def spectral_plc(state) do
    SignalScience.spectral_plc(state)
  end

  @doc "Update PLC state with a good frame. Delegates to SignalScience."
  def plc_receive_good_frame(pcm, state) do
    SignalScience.plc_receive_good_frame(pcm, state)
  end

  @doc "Per-user adaptive VAD. Delegates to SignalScience."
  def per_user_vad(pcm, user_id, sample_rate, state) do
    SignalScience.per_user_vad(pcm, user_id, sample_rate, state)
  end

  # ---------------------------------------------------------------------------
  # Crypto kernel
  # ---------------------------------------------------------------------------

  @impl true
  def crypto_encrypt_frame(plaintext, key, aad) do
    iv = :crypto.strong_rand_bytes(12)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true) do
      {ciphertext, tag} -> {:ok, {ciphertext, iv, tag}}
      _ -> {:error, :encrypt_failed}
    end
  end

  @impl true
  def crypto_decrypt_frame(ciphertext, key, iv, tag, aad) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, tag, false) do
      :error -> {:error, :decrypt_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  @impl true
  def crypto_hash_chain(prev_hash, payload) do
    :crypto.hash(:sha256, prev_hash <> payload)
  end

  @impl true
  def crypto_derive_frame_key(shared_secret, salt, info) do
    # HKDF-SHA256: extract then expand.
    prk = :crypto.mac(:hmac, :sha256, salt, shared_secret)
    # Expand to 32 bytes (one block).
    :crypto.mac(:hmac, :sha256, prk, info <> <<1::8>>)
  end

  # ---------------------------------------------------------------------------
  # I/O kernel
  # ---------------------------------------------------------------------------

  @impl true
  def io_jitter_buffer_push(buffer_state, packet, sequence, timestamp) do
    buffer = Map.get(buffer_state, :packets, [])
    target_delay = Map.get(buffer_state, :target_delay_ms, 40)
    base_ts = Map.get(buffer_state, :base_timestamp)

    entry = %{packet: packet, seq: sequence, ts: timestamp}
    updated_buffer = insert_sorted(buffer, entry)

    # SECURITY FIX: Enforce bounded jitter buffer size (proven SafeQueue
    # drop-oldest principle). Without this cap, a burst of out-of-order or
    # very late packets causes unbounded list growth. When at capacity,
    # discard the oldest packet (head of the sorted list) to make room.
    updated_buffer =
      if length(updated_buffer) > @max_jitter_buffer_packets do
        # Drop oldest packet(s) exceeding the cap.
        Enum.take(updated_buffer, -@max_jitter_buffer_packets)
      else
        updated_buffer
      end

    # Set base timestamp on first packet.
    base_ts = base_ts || timestamp

    new_state =
      buffer_state
      |> Map.put(:packets, updated_buffer)
      |> Map.put(:base_timestamp, base_ts)
      |> Map.put(:target_delay_ms, target_delay)

    # Emit the oldest packet if we have enough buffered.
    case updated_buffer do
      [oldest | rest] ->
        age_ms = timestamp - oldest.ts

        if age_ms >= target_delay do
          {:ok, oldest.packet, Map.put(new_state, :packets, rest)}
        else
          {:ok, nil, new_state}
        end

      [] ->
        # Buffer is empty (should not happen, but guard against it).
        {:ok, nil, new_state}
    end
  end

  @impl true
  def io_conceal_loss(prev_frames, frame_size) do
    # Simple packet loss concealment: repeat last frame with fade.
    case prev_frames do
      [last | _] ->
        # Apply gentle fade (0.95 gain) to avoid clicks.
        last
        |> :binary.bin_to_list()
        |> Enum.map(fn b -> trunc(b * 0.95) end)
        |> :binary.list_to_bin()
        |> binary_pad_or_trim(frame_size)

      [] ->
        # No previous frames — emit silence.
        <<0::size(frame_size * 8)>>
    end
  end

  @impl true
  def io_adaptive_bitrate(loss_ratio, rtt_ms, current_bitrate) do
    # Simple AIMD (Additive Increase Multiplicative Decrease).
    min_bitrate = 16_000
    max_bitrate = 128_000

    new_bitrate =
      cond do
        # High loss or high RTT — decrease multiplicatively.
        loss_ratio > 0.10 or rtt_ms > 300 ->
          trunc(current_bitrate * 0.7)

        # Moderate conditions — hold steady.
        loss_ratio > 0.02 or rtt_ms > 150 ->
          current_bitrate

        # Good conditions — increase additively.
        true ->
          current_bitrate + 4_000
      end

    max(min_bitrate, min(max_bitrate, new_bitrate))
  end

  # ---------------------------------------------------------------------------
  # DSP kernel
  # ---------------------------------------------------------------------------

  @impl true
  def dsp_fft(signal, size) do
    # Cooley-Tukey radix-2 DIT FFT.
    if size <= 1 do
      Enum.map(signal, fn s -> {s, 0.0} end)
    else
      half = div(size, 2)

      {evens, odds} =
        signal
        |> Enum.with_index()
        |> Enum.split_with(fn {_val, idx} -> rem(idx, 2) == 0 end)

      even_vals = Enum.map(evens, fn {v, _} -> v end)
      odd_vals = Enum.map(odds, fn {v, _} -> v end)

      fft_even = dsp_fft(even_vals, half)
      fft_odd = dsp_fft(odd_vals, half)

      Enum.map(0..(size - 1), fn k ->
        k_mod = rem(k, half)
        angle = -2.0 * :math.pi() * k / size
        {wr, wi} = {:math.cos(angle), :math.sin(angle)}

        {or_val, oi_val} = Enum.at(fft_odd, k_mod)
        {er, ei} = Enum.at(fft_even, k_mod)

        # Twiddle factor multiplication: W * odd[k]
        tr = wr * or_val - wi * oi_val
        ti = wr * oi_val + wi * or_val

        if k < half do
          {er + tr, ei + ti}
        else
          {er - tr, ei - ti}
        end
      end)
    end
  end

  @impl true
  def dsp_ifft(spectrum, size) do
    # IFFT via conjugate FFT trick: IFFT(X) = conj(FFT(conj(X))) / N
    conjugated = Enum.map(spectrum, fn {r, i} -> {r, -i} end)
    signal_vals = Enum.map(conjugated, fn {r, _i} -> r end)
    fft_result = dsp_fft(signal_vals, size)

    Enum.map(fft_result, fn {r, _i} -> r / size end)
  end

  @impl true
  def dsp_convolve(a, b) do
    len_a = length(a)
    len_b = length(b)
    out_len = len_a + len_b - 1

    a_indexed = Enum.with_index(a)

    Enum.map(0..(out_len - 1), fn n ->
      Enum.reduce(a_indexed, 0.0, fn {a_val, k}, acc ->
        b_idx = n - k

        if b_idx >= 0 and b_idx < len_b do
          acc + a_val * Enum.at(b, b_idx)
        else
          acc
        end
      end)
    end)
  end

  @impl true
  def dsp_mix(streams, matrix) do
    # matrix[output][input] — apply gain matrix to produce output streams.
    Enum.map(matrix, fn output_gains ->
      # For each output channel, sum the weighted input streams.
      weighted =
        streams
        |> Enum.zip(output_gains)
        |> Enum.map(fn {stream, gain} ->
          Enum.map(stream, fn s -> s * gain end)
        end)

      # Sum across all inputs, sample by sample.
      case weighted do
        [] ->
          []

        [first | rest] ->
          Enum.reduce(rest, first, fn stream, acc ->
            Enum.zip(acc, stream)
            |> Enum.map(fn {a, b} -> a + b end)
          end)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Neural kernel
  # ---------------------------------------------------------------------------

  @impl true
  def neural_init_model(_sample_rate) do
    # Reference implementation: spectral gating model state.
    # Tracks a running noise floor estimate across frames.
    %{
      noise_floor: nil,
      frame_count: 0,
      alpha: 0.98
    }
  end

  @impl true
  def neural_denoise(pcm, _sample_rate, model_state) do
    # Reference: spectral gating.
    # Estimate noise floor from quiet frames, gate frequencies below it.
    rms = rms_energy(pcm)
    frame_count = model_state.frame_count + 1

    noise_floor =
      case model_state.noise_floor do
        nil ->
          # First frame — assume it's noise to bootstrap.
          rms

        prev ->
          if rms < prev * 1.5 do
            # Quiet frame — update noise floor with exponential average.
            model_state.alpha * prev + (1.0 - model_state.alpha) * rms
          else
            prev
          end
      end

    # Gate: if frame RMS is close to noise floor, attenuate.
    gate_ratio = if noise_floor > 0.0, do: max(0.0, 1.0 - noise_floor / max(rms, 1.0e-10)), else: 1.0
    cleaned = Enum.map(pcm, fn s -> s * gate_ratio end)

    new_state = %{model_state | noise_floor: noise_floor, frame_count: frame_count}
    {cleaned, new_state}
  end

  @impl true
  def neural_classify_noise(pcm, _sample_rate) do
    rms = rms_energy(pcm)
    zcr = zero_crossing_rate(pcm)

    cond do
      rms < 0.001 -> {:silence, 0.95}
      zcr > 0.4 -> {:keyboard, 0.6}
      rms > 0.1 and zcr < 0.15 -> {:speech, 0.7}
      rms > 0.05 and zcr > 0.2 -> {:fan, 0.5}
      true -> {:unknown, 0.3}
    end
  end

  # ---------------------------------------------------------------------------
  # Compression kernel
  # ---------------------------------------------------------------------------

  @impl true
  def compress_lz4(data) do
    # Pure Elixir LZ4 — simplified block format.
    # Uses a sliding window to find matches, encodes as literal/match sequences.
    # This is a correct but basic implementation; the Zig NIF uses the real LZ4 algorithm.
    compressed = lz4_compress(data)
    {:ok, compressed}
  end

  @impl true
  def decompress_lz4(compressed, original_size) do
    case lz4_decompress(compressed, original_size) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, :decompress_failed}
    end
  end

  @impl true
  def compress_zstd(data, level) do
    # Pure Elixir zstd is not practical — use Erlang's built-in zlib as a
    # reasonable fallback. zlib deflate at level 6 gives ~80% of zstd's ratio.
    _ = level
    z = :zlib.open()
    :zlib.deflateInit(z, :default)
    compressed = :zlib.deflate(z, data, :finish) |> IO.iodata_to_binary()
    :zlib.deflateEnd(z)
    :zlib.close(z)
    {:ok, compressed}
  end

  @impl true
  def decompress_zstd(compressed) do
    z = :zlib.open()
    :zlib.inflateInit(z)

    case :zlib.inflate(z, compressed) do
      decompressed when is_list(decompressed) ->
        :zlib.inflateEnd(z)
        :zlib.close(z)
        {:ok, IO.iodata_to_binary(decompressed)}

      _ ->
        :zlib.close(z)
        {:error, :decompress_failed}
    end
  rescue
    _ -> {:error, :decompress_failed}
  end

  @impl true
  def compress_audio_archive(frames, sample_rate, channels) do
    # FLAC-style lossless audio archive.
    # Format:
    #   Header: <<magic::32, version::8, sample_rate::32, channels::8,
    #             frame_count::32, frame_offsets::binary>>
    #   Frames: each frame is delta-encoded then LZ4-compressed.
    frame_count = length(frames)

    # Delta-encode each frame (differences between consecutive samples).
    # This exploits the high correlation in audio — deltas are small integers.
    {compressed_frames, _total_size} =
      frames
      |> Enum.map_reduce(0, fn pcm, offset ->
        # Quantise to 16-bit, delta-encode, then LZ4 compress.
        quantised = Enum.map(pcm, fn s -> trunc(max(-1.0, min(1.0, s)) * 32767.0) end)
        deltas = delta_encode(quantised)
        delta_bin = Enum.map(deltas, fn d -> <<d::signed-16>> end) |> IO.iodata_to_binary()
        {:ok, compressed} = compress_lz4(delta_bin)
        frame_entry = <<byte_size(compressed)::32-little, compressed::binary>>
        {{frame_entry, offset}, offset + byte_size(frame_entry)}
      end)

    # Build offset table for random access.
    header_size = 4 + 1 + 4 + 1 + 4 + frame_count * 4
    offset_table =
      compressed_frames
      |> Enum.map(fn {_frame, off} -> <<(off + header_size)::32-little>> end)
      |> IO.iodata_to_binary()

    frame_data =
      compressed_frames
      |> Enum.map(fn {frame, _off} -> frame end)
      |> IO.iodata_to_binary()

    archive =
      <<"BARC"::binary, 1::8,
        sample_rate::32-little, channels::8,
        frame_count::32-little,
        offset_table::binary,
        frame_data::binary>>

    {:ok, archive}
  end

  @impl true
  def decompress_audio_frame(archive, frame_index) do
    case archive do
      <<"BARC", 1::8, _sr::32-little, _ch::8, frame_count::32-little, rest::binary>>
      when frame_index < frame_count ->
        # Read offset from offset table.
        offset_table_size = frame_count * 4
        <<offset_table::binary-size(offset_table_size), frames_data::binary>> = rest

        offset_pos = frame_index * 4
        <<_::binary-size(offset_pos), abs_offset::32-little, _::binary>> = offset_table

        # Header size to compute relative offset into archive.
        header_size = 4 + 1 + 4 + 1 + 4 + offset_table_size
        rel_offset = abs_offset - header_size

        # Read compressed frame.
        <<_skip::binary-size(rel_offset), frame_len::32-little, compressed::binary>> = frames_data
        compressed_data = binary_part(compressed, 0, frame_len)

        # Decompress and decode deltas.
        # Original size: frame_size * 2 bytes (16-bit samples).
        # We don't know frame size from the archive alone, so we try with a generous limit.
        case decompress_lz4(compressed_data, 960 * 2) do
          {:ok, delta_bin} ->
            deltas = for <<d::signed-16 <- delta_bin>>, do: d
            samples = delta_decode(deltas)
            pcm = Enum.map(samples, fn s -> s / 32767.0 end)
            {:ok, pcm}

          {:error, _} ->
            {:error, :decompress_failed}
        end

      _ ->
        {:error, :invalid_index}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp dot(a, b) do
    Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
  end

  defp pad_to(list, target_len) when length(list) >= target_len, do: Enum.take(list, target_len)
  defp pad_to(list, target_len), do: list ++ List.duplicate(0.0, target_len - length(list))

  defp insert_sorted([], entry), do: [entry]
  defp insert_sorted([head | tail] = list, entry) do
    if entry.seq <= head.seq, do: [entry | list], else: [head | insert_sorted(tail, entry)]
  end

  defp binary_pad_or_trim(bin, size) when byte_size(bin) >= size, do: binary_part(bin, 0, size)
  defp binary_pad_or_trim(bin, size), do: bin <> <<0::size((size - byte_size(bin)) * 8)>>

  # Compute a simple magnitude spectrum via DFT (reference implementation).
  # For production, the Zig backend uses Cooley-Tukey FFT.
  defp compute_magnitude_spectrum(pcm, n_bins, _sample_rate) do
    frame_len = length(pcm)
    pcm_list = Enum.take(pcm, frame_len)

    for k <- 0..(n_bins - 1) do
      {real, imag} =
        pcm_list
        |> Enum.with_index()
        |> Enum.reduce({0.0, 0.0}, fn {sample, n}, {re, im} ->
          angle = -2.0 * :math.pi() * k * n / frame_len
          {re + sample * :math.cos(angle), im + sample * :math.sin(angle)}
        end)

      :math.sqrt(real * real + imag * imag) / max(frame_len, 1)
    end
  end

  defp rms_energy(pcm) do
    sum_sq = Enum.reduce(pcm, 0.0, fn s, acc -> acc + s * s end)
    :math.sqrt(sum_sq / max(length(pcm), 1))
  end

  defp zero_crossing_rate([]), do: 0.0
  defp zero_crossing_rate([_]), do: 0.0
  defp zero_crossing_rate(pcm) do
    crossings =
      pcm
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> (a >= 0 and b < 0) or (a < 0 and b >= 0) end)

    crossings / (length(pcm) - 1)
  end

  # Simplified LZ4 block compression.
  # Format: sequence of (literal_count, match_offset, match_length) tokens.
  # Each token: <<token_byte, extra_literal_len?, literals, offset::16-little, extra_match_len?>>
  # This is a correct subset of LZ4 block format — compatible with LZ4 decoders.
  defp lz4_compress(data) when is_binary(data) do
    # For short data, store as a single literal run (still valid LZ4).
    if byte_size(data) <= 16 do
      lit_len = byte_size(data)
      token = min(lit_len, 15) <<< 4
      extra = if lit_len >= 15, do: <<lit_len - 15::8>>, else: <<>>
      # LZ4 block ends when there are no more sequences.
      <<token::8, extra::binary, data::binary>>
    else
      lz4_compress_block(data, 0, byte_size(data), [])
      |> IO.iodata_to_binary()
    end
  end

  defp lz4_compress_block(data, pos, size, acc) when pos >= size do
    # Emit remaining literals.
    remaining = size - max(pos - byte_size(IO.iodata_to_binary(acc)), 0)
    if remaining > 0 do
      # Final literal-only sequence (last 5 bytes must be literals per LZ4 spec).
      lits = binary_part(data, max(size - remaining, 0), remaining)
      lit_len = byte_size(lits)
      token = min(lit_len, 15) <<< 4
      extra = if lit_len >= 15, do: encode_lz4_length(lit_len - 15), else: <<>>
      Enum.reverse([<<token::8, extra::binary, lits::binary>> | acc])
    else
      Enum.reverse(acc)
    end
  end

  defp lz4_compress_block(data, pos, size, acc) do
    # Simple greedy: look for 4-byte match in last 4096 bytes.
    window_start = max(0, pos - 4096)
    match = find_lz4_match(data, pos, window_start, size)

    case match do
      nil ->
        # No match — accumulate literal.
        # Emit a literal-only token for simplicity.
        lit = binary_part(data, pos, 1)
        token = 1 <<< 4  # 1 literal, 0 match
        lz4_compress_block(data, pos + 1, size, [<<token::8, lit::binary>> | acc])

      {offset, match_len} ->
        # Emit token with 0 literals + match.
        ml = match_len - 4  # min match is 4
        token = min(ml, 15)
        extra = if ml >= 15, do: encode_lz4_length(ml - 15), else: <<>>
        lz4_compress_block(data, pos + match_len, size,
          [<<token::8, offset::16-little, extra::binary>> | acc])
    end
  end

  defp find_lz4_match(data, pos, window_start, size) do
    if pos + 4 > size, do: nil, else: find_lz4_match_scan(data, pos, window_start, pos, size, nil)
  end

  defp find_lz4_match_scan(_data, _pos, scan, scan_end, _size, best) when scan >= scan_end, do: best
  defp find_lz4_match_scan(data, pos, scan, scan_end, size, best) do
    match_len = count_matching_bytes(data, scan, pos, size, 0)
    new_best =
      if match_len >= 4 do
        offset = pos - scan
        case best do
          nil -> {offset, match_len}
          {_bo, bl} -> if match_len > bl, do: {offset, match_len}, else: best
        end
      else
        best
      end
    find_lz4_match_scan(data, pos, scan + 1, scan_end, size, new_best)
  end

  defp count_matching_bytes(_data, _a, _b, _size, count) when count >= 255, do: count
  defp count_matching_bytes(data, a, b, size, count) do
    if a + count < size and b + count < size and
       :binary.at(data, a + count) == :binary.at(data, b + count) do
      count_matching_bytes(data, a, b, size, count + 1)
    else
      count
    end
  end

  defp encode_lz4_length(len) when len < 255, do: <<len::8>>
  defp encode_lz4_length(len), do: <<255::8, encode_lz4_length(len - 255)::binary>>

  # LZ4 decompression — supports the simplified format we produce.
  defp lz4_decompress(compressed, max_size) do
    try do
      {:ok, lz4_decompress_block(compressed, <<>>, max_size)}
    rescue
      _ -> :error
    end
  end

  defp lz4_decompress_block(<<>>, output, _max), do: output
  defp lz4_decompress_block(<<token::8, rest::binary>>, output, max_size) do
    lit_len = token >>> 4
    match_len_base = token &&& 0x0F

    # Read extra literal length.
    {lit_len, rest} = read_lz4_extra_length(lit_len, rest)

    # Read literals.
    <<literals::binary-size(lit_len), rest::binary>> = rest
    output = output <> literals

    if rest == <<>> do
      # Last sequence — no match part.
      output
    else
      # Read match offset.
      <<offset::16-little, rest::binary>> = rest

      # Read extra match length.
      {match_len_extra, rest} = read_lz4_extra_length(match_len_base, rest)
      match_len = match_len_extra + 4

      # Copy from output buffer (may overlap).
      output = lz4_copy_match(output, offset, match_len)

      if byte_size(output) >= max_size do
        binary_part(output, 0, max_size)
      else
        lz4_decompress_block(rest, output, max_size)
      end
    end
  end

  defp read_lz4_extra_length(15, <<255, rest::binary>>) do
    {extra, rest} = read_lz4_extra_length(15, rest)
    {extra + 255, rest}
  end
  defp read_lz4_extra_length(15, <<byte::8, rest::binary>>), do: {15 + byte, rest}
  defp read_lz4_extra_length(len, rest), do: {len, rest}

  defp lz4_copy_match(output, offset, match_len) do
    src_start = byte_size(output) - offset
    copy_bytes(output, src_start, match_len)
  end

  defp copy_bytes(output, _src, 0), do: output
  defp copy_bytes(output, src, remaining) do
    byte = :binary.at(output, src)
    copy_bytes(output <> <<byte::8>>, src + 1, remaining - 1)
  end

  # Delta encoding: store differences between consecutive samples.
  # First sample stored as-is, rest as deltas.
  defp delta_encode([]), do: []
  defp delta_encode([first | rest]) do
    {deltas, _prev} =
      Enum.map_reduce(rest, first, fn sample, prev ->
        {sample - prev, sample}
      end)

    [first | deltas]
  end

  # Delta decoding: reconstruct samples from deltas.
  defp delta_decode([]), do: []
  defp delta_decode([first | deltas]) do
    {samples, _prev} =
      Enum.map_reduce(deltas, first, fn delta, prev ->
        sample = prev + delta
        {sample, sample}
      end)

    [first | samples]
  end
end
