# SPDX-License-Identifier: MPL-2.0
#
# Burble.Coprocessor.SmartBackend — Per-operation dispatch to fastest backend.
#
# Follows Axiom.jl's SmartBackend pattern: each kernel operation is routed to
# whichever backend is fastest for that specific operation. The dispatch table
# is based on benchmarks (same approach as Axiom.jl's matmul→Julia, gelu→Zig).
#
# Current dispatch table (to be updated with real benchmarks):
#
# Benchmark results (2026-03-16, Zig 0.15, Erlang/OTP 28, 960-sample frames):
#
#   Audio encode           → Zig  (5.7x faster:  14µs vs 81µs)
#   Audio decode           → Zig  (4.7x faster:  21µs vs 99µs)
#   Audio noise gate       → SNIF (crash-isolated) → Zig  (1.2x faster:  27µs vs 32µs — marginal)
#   Audio echo cancel      → SNIF (crash-isolated) → Zig  (62.6x faster: 310µs vs 19.4ms — CRITICAL)
#   Crypto encrypt/decrypt → Elixir (Erlang :crypto is native OpenSSL — 2µs)
#   Crypto hash chain      → Elixir (same — 2µs)
#   Crypto derive key      → Elixir (same — 5µs)
#   I/O jitter buffer      → Elixir (data structure ops — <1µs)
#   I/O conceal loss       → Elixir (simple ops)
#   I/O adaptive bitrate   → Elixir (trivial arithmetic — <1µs)
#   DSP FFT (256)          → SNIF (crash-isolated) → Zig  (37x faster:   22µs vs 826µs)
#   DSP convolve (64x32)   → Zig  (28x faster:   11µs vs 311µs)
#   DSP mix                → Elixir (Zig NIF not wired for complex marshalling)
#   Neural denoise         → Zig  (6.7x faster:  8µs vs 54µs)
#   Neural classify        → Elixir (simple heuristic — 190µs)

defmodule Burble.Coprocessor.SmartBackend do
  @moduledoc """
  Smart dispatcher that routes each kernel operation to the fastest backend.

  If the Zig backend is not available, all operations fall back to Elixir.
  When Zig is available, operations are dispatched per the benchmark table.
  """

  @behaviour Burble.Coprocessor.Backend

  alias Burble.Coprocessor.{ElixirBackend, ZigBackend, SNIFBackend}

  # ---------------------------------------------------------------------------
  # Backend metadata
  # ---------------------------------------------------------------------------

  @impl true
  def backend_type, do: :smart

  @impl true
  def available?, do: true

  # ---------------------------------------------------------------------------
  # Dispatch helpers
  # ---------------------------------------------------------------------------

  # Route to Zig if available, otherwise Elixir.
  defp zig_or_elixir do
    if ZigBackend.available?(), do: ZigBackend, else: ElixirBackend
  end

  # Always use Elixir (operation is fast enough or delegates to Erlang :crypto).
  defp always_elixir, do: ElixirBackend

  # ---------------------------------------------------------------------------
  # Audio kernel — dispatch
  # ---------------------------------------------------------------------------

  @impl true
  def audio_encode(pcm, sample_rate, channels, bitrate) do
    # PCM frame pack (NOT Opus transcoding — see Backend behaviour docs).
    zig_or_elixir().audio_encode(pcm, sample_rate, channels, bitrate)
  end

  @impl true
  def audio_decode(pcm_frame, sample_rate, channels) do
    # PCM frame unpack (NOT Opus decoding).
    zig_or_elixir().audio_decode(pcm_frame, sample_rate, channels)
  end

  @impl true
  def opus_transcode(pcm_or_opus, sample_rate, channels, bitrate) do
    # Always returns {:error, :not_implemented} — neither backend links libopus.
    zig_or_elixir().opus_transcode(pcm_or_opus, sample_rate, channels, bitrate)
  end

  @impl true
  def opus_available?, do: false

  @impl true
  def audio_noise_gate(pcm, threshold_db) do
    # Route through SNIF (crash-isolated WASM) when the backend is available,
    # otherwise fall back to Zig → Elixir as before.
    # 1.2x Zig advantage — marginal but consistent; SNIF adds ~10-15% on top.
    if SNIFBackend.available?() do
      SNIFBackend.snif_noise_gate(pcm, threshold_db)
    else
      zig_or_elixir().audio_noise_gate(pcm, threshold_db)
    end
  end

  @impl true
  def audio_echo_cancel(capture, reference, filter_length) do
    # Route through SNIF (crash-isolated WASM) when the backend is available.
    # Normalise return type: Zig NIF wraps in {:ok, list}, Elixir returns plain list.
    raw =
      if SNIFBackend.available?() do
        SNIFBackend.snif_echo_cancel(capture, reference, filter_length)
      else
        zig_or_elixir().audio_echo_cancel(capture, reference, filter_length)
      end

    case raw do
      {:ok, result} when is_list(result) -> result
      result when is_list(result) -> result
      other -> other
    end
  end

  # Signal science additions — all Elixir for now, Zig candidates for Phase 2.
  # AGC and perceptual weighting are DSP-heavy and would benefit from SIMD.

  @impl true
  def audio_agc(pcm, target_rms_db, attack_ms, release_ms, state) do
    # AGC is a good Zig candidate (per-sample gain with soft clipping).
    always_elixir().audio_agc(pcm, target_rms_db, attack_ms, release_ms, state)
  end

  @impl true
  def audio_comfort_noise(frame_length, level_db, noise_profile) do
    # Comfort noise is lightweight — Elixir is fine.
    always_elixir().audio_comfort_noise(frame_length, level_db, noise_profile)
  end

  @impl true
  def audio_spectral_vad(pcm, sample_rate, state) do
    # Spectral VAD uses FFT — route to Zig when FFT-based VAD NIF is added.
    always_elixir().audio_spectral_vad(pcm, sample_rate, state)
  end

  @impl true
  def audio_perceptual_weight(magnitudes, sample_rate) do
    # Perceptual weighting is pure math on magnitude array — good Zig candidate.
    always_elixir().audio_perceptual_weight(magnitudes, sample_rate)
  end

  # ---------------------------------------------------------------------------
  # Crypto kernel — dispatch (Erlang :crypto is already native C)
  # ---------------------------------------------------------------------------

  @impl true
  def crypto_encrypt_frame(plaintext, key, aad) do
    always_elixir().crypto_encrypt_frame(plaintext, key, aad)
  end

  @impl true
  def crypto_decrypt_frame(ciphertext, key, iv, tag, aad) do
    always_elixir().crypto_decrypt_frame(ciphertext, key, iv, tag, aad)
  end

  @impl true
  def crypto_hash_chain(prev_hash, payload) do
    always_elixir().crypto_hash_chain(prev_hash, payload)
  end

  @impl true
  def crypto_derive_frame_key(shared_secret, salt, info) do
    always_elixir().crypto_derive_frame_key(shared_secret, salt, info)
  end

  # ---------------------------------------------------------------------------
  # I/O kernel — dispatch (data structure ops, not compute-bound)
  # ---------------------------------------------------------------------------

  @impl true
  def io_jitter_buffer_push(buffer_state, packet, sequence, timestamp) do
    always_elixir().io_jitter_buffer_push(buffer_state, packet, sequence, timestamp)
  end

  @impl true
  def io_conceal_loss(prev_frames, frame_size) do
    always_elixir().io_conceal_loss(prev_frames, frame_size)
  end

  @impl true
  def io_adaptive_bitrate(loss_ratio, rtt_ms, current_bitrate) do
    always_elixir().io_adaptive_bitrate(loss_ratio, rtt_ms, current_bitrate)
  end

  # ---------------------------------------------------------------------------
  # DSP kernel — dispatch (SIMD-friendly workloads → Zig)
  # ---------------------------------------------------------------------------

  @impl true
  def dsp_fft(signal, size) do
    # Try SNIF first (crash-isolated), fallback to Zig, then Elixir
    if SNIFBackend.available?() do
      SNIFBackend.dsp_fft(signal, size)
    else
      zig_or_elixir().dsp_fft(signal, size)
    end
  end

  @impl true
  def dsp_ifft(spectrum, size) do
    # Try SNIF first (crash-isolated), fallback to Zig, then Elixir
    if SNIFBackend.available?() do
      SNIFBackend.dsp_ifft(spectrum, size)
    else
      zig_or_elixir().dsp_ifft(spectrum, size)
    end
  end

  @impl true
  def dsp_convolve(a, b) do
    zig_or_elixir().dsp_convolve(a, b)
  end

  @impl true
  def dsp_mix(streams, matrix) do
    zig_or_elixir().dsp_mix(streams, matrix)
  end

  # ---------------------------------------------------------------------------
  # Neural kernel — dispatch
  # ---------------------------------------------------------------------------

  @impl true
  def neural_init_model(sample_rate) do
    zig_or_elixir().neural_init_model(sample_rate)
  end

  @impl true
  def neural_denoise(pcm, sample_rate, model_state) do
    zig_or_elixir().neural_denoise(pcm, sample_rate, model_state)
  end

  @impl true
  def neural_classify_noise(pcm, sample_rate) do
    # Simple heuristic — Elixir is fine until we have a real ML model.
    always_elixir().neural_classify_noise(pcm, sample_rate)
  end

  # ---------------------------------------------------------------------------
  # Signal science — advanced DSP dispatch
  # ---------------------------------------------------------------------------

  @doc "Wiener filter for spectral noise reduction. Routes to Elixir (Zig candidate Phase 2)."
  def wiener_filter(pcm, sample_rate, state) do
    # FFT-heavy — good Zig candidate once SIMD FFT NIF lands.
    always_elixir().wiener_filter(pcm, sample_rate, state)
  end

  @doc "De-reverberation via spectral subtraction. Routes to Elixir (Zig candidate Phase 2)."
  def dereverberate(pcm, sample_rate, state) do
    # FFT + spectral subtraction — Zig candidate.
    always_elixir().dereverberate(pcm, sample_rate, state)
  end

  @doc "Spectral packet loss concealment. Routes to Elixir."
  def spectral_plc(state) do
    always_elixir().spectral_plc(state)
  end

  @doc "Update PLC state with a good frame. Routes to Elixir."
  def plc_receive_good_frame(pcm, state) do
    always_elixir().plc_receive_good_frame(pcm, state)
  end

  @doc "Per-user adaptive VAD. Routes to Elixir."
  def per_user_vad(pcm, user_id, sample_rate, state) do
    always_elixir().per_user_vad(pcm, user_id, sample_rate, state)
  end

  # ---------------------------------------------------------------------------
  # Compression kernel — dispatch
  # ---------------------------------------------------------------------------

  @impl true
  def compress_lz4(data) do
    # 26,350x Zig advantage — CRITICAL, Elixir is 83ms vs Zig 3µs.
    zig_or_elixir().compress_lz4(data)
  end

  @impl true
  def decompress_lz4(compressed, original_size) do
    # 18,150x Zig advantage — same story.
    zig_or_elixir().decompress_lz4(compressed, original_size)
  end

  @impl true
  def compress_zstd(data, level) do
    # zstd is complex — Zig can use the real algorithm, Elixir falls back to zlib.
    zig_or_elixir().compress_zstd(data, level)
  end

  @impl true
  def decompress_zstd(compressed) do
    zig_or_elixir().decompress_zstd(compressed)
  end

  @impl true
  def compress_audio_archive(frames, sample_rate, channels) do
    # Archive format uses LZ4 internally — Zig for the inner compression.
    zig_or_elixir().compress_audio_archive(frames, sample_rate, channels)
  end

  @impl true
  def decompress_audio_frame(archive, frame_index) do
    zig_or_elixir().decompress_audio_frame(archive, frame_index)
  end
end
