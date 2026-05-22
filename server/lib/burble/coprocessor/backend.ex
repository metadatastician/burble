# SPDX-License-Identifier: MPL-2.0
#
# Burble.Coprocessor.Backend — Abstract backend behaviour for audio kernels.
#
# Follows the Axiom.jl pattern: abstract backend → kernel interface → dispatch.
# Each kernel operation is defined as a callback. Concrete backends implement
# the callbacks using either pure Elixir (reference) or Zig FFI (hot path).
#
# The SmartBackend dispatches each operation to whichever backend is fastest,
# measured by benchmarks (same approach as Axiom.jl's SmartBackend).
#
# Backend hierarchy:
#   AbstractBackend (behaviour)
#     ├── ElixirBackend    — pure Elixir reference implementation
#     ├── ZigBackend       — Zig NIFs for hot-path operations
#     └── SmartBackend     — dispatcher routing per-operation
#
# Kernel domains:
#   Audio   — PCM frame pack/unpack (NOT Opus transcoding — see note below),
#             noise suppression, echo cancellation
#   Crypto  — AES-GCM frame encryption, Avow hash chains
#   IO      — jitter buffer, packet loss concealment, adaptive bitrate
#   DSP     — FFT, convolution, mixing matrix
#   Neural  — ML-based noise suppression (keyboard/fan/dog removal)
#
# Opus transcoding is NOT performed server-side. Burble is an E2EE-opaque
# SFU: clients encode Opus in the browser's WebRTC stack; the server forwards
# ciphertext frames without decoding. The audio_encode/audio_decode callbacks
# below pack raw PCM into length-prefixed frames — they are used for
# recording/archive/benchmark paths only, not for transcoding live RTP. An
# explicit `opus_transcode/4` callback returns {:error, :not_implemented} to
# make this contract enforceable. Real Opus would require linking libopus;
# see STATE.a2ml [migration] for the deferred decision.

defmodule Burble.Coprocessor.Backend do
  @moduledoc """
  Abstract backend behaviour for Burble's coprocessor kernels.

  Defines the kernel interface that all backends must implement.
  Operations are grouped by domain (audio, crypto, io, dsp, neural)
  and dispatched via `Burble.Coprocessor.SmartBackend` to the
  fastest available implementation.

  ## Implementing a new backend

  ```elixir
  defmodule MyBackend do
    @behaviour Burble.Coprocessor.Backend

    @impl true
    def backend_type, do: :custom

    @impl true
    def available?, do: true

    # ... implement all callbacks ...
  end
  ```
  """

  # ---------------------------------------------------------------------------
  # Backend metadata
  # ---------------------------------------------------------------------------

  @doc "Atom identifying this backend type (:elixir, :zig, :smart)."
  @callback backend_type() :: atom()

  @doc "Whether this backend is available and initialised."
  @callback available?() :: boolean()

  # ---------------------------------------------------------------------------
  # Audio kernel — PCM frame pack/unpack, noise gate, echo cancellation
  # ---------------------------------------------------------------------------

  @doc """
  Pack raw PCM samples into a length-prefixed binary frame.

  **This is NOT Opus encoding.** Clients perform Opus encoding in the
  browser's WebRTC stack; the server does not transcode live RTP. This
  callback is used for recording, archive, and self-test loopback paths
  where raw PCM framing is needed.

  The `bitrate` parameter is accepted for API stability but is currently
  ignored — no compression is performed. Call `opus_transcode/4` explicitly
  if you need real Opus (it will return `{:error, :not_implemented}` until
  libopus is linked).

  ## Parameters
    * `pcm` — Raw PCM samples as a list of floats (normalised -1.0..1.0)
    * `sample_rate` — Sample rate in Hz (typically 48000); informational
    * `channels` — Channel count (1 = mono, 2 = stereo)
    * `bitrate` — Currently ignored; retained for API compatibility

  Returns `{:ok, frame_binary}` or `{:error, reason}`. The binary is
  round-trippable through `audio_decode/3`.
  """
  @callback audio_encode(
              pcm :: [float()],
              sample_rate :: pos_integer(),
              channels :: 1 | 2,
              bitrate :: pos_integer()
            ) :: {:ok, binary()} | {:error, term()}

  @doc """
  Unpack a length-prefixed PCM frame (produced by `audio_encode/4`)
  back into normalised float samples.

  **This is NOT Opus decoding.** See `audio_encode/4` docs for the
  SFU-opaque rationale.

  Returns `{:ok, pcm_floats}` or `{:error, :invalid_frame}`.
  """
  @callback audio_decode(
              pcm_frame :: binary(),
              sample_rate :: pos_integer(),
              channels :: 1 | 2
            ) :: {:ok, [float()]} | {:error, term()}

  @doc """
  Transcode raw PCM to a real Opus frame (or real Opus to PCM if `pcm` is a
  binary starting with the Opus TOC).

  **Currently returns `{:error, :not_implemented}` on all backends.**
  This callback exists so that callers intending real Opus transcoding fail
  loudly rather than silently round-tripping raw PCM through
  `audio_encode/4`. Implementing this requires linking libopus; the decision
  is tracked in STATE.a2ml [migration].
  """
  @callback opus_transcode(
              pcm_or_opus :: [float()] | binary(),
              sample_rate :: pos_integer(),
              channels :: 1 | 2,
              bitrate :: pos_integer()
            ) :: {:error, :not_implemented}

  @doc """
  Whether this backend can perform real Opus transcoding.

  Returns `false` on every backend until libopus is linked.
  """
  @callback opus_available?() :: boolean()

  @doc """
  Apply noise gate to PCM samples.

  Samples below `threshold_db` are zeroed. Simple but effective for
  silencing background noise between speech.

  Returns filtered PCM samples.
  """
  @callback audio_noise_gate(
              pcm :: [float()],
              threshold_db :: float()
            ) :: [float()]

  @doc """
  Apply echo cancellation to a capture frame given a reference (playback) frame.

  Uses NLMS (Normalised Least Mean Squares) adaptive filter.
  The `filter_length` controls how many taps the filter uses.

  Returns echo-cancelled PCM samples.
  """
  @callback audio_echo_cancel(
              capture :: [float()],
              reference :: [float()],
              filter_length :: pos_integer()
            ) :: [float()]

  @doc """
  Automatic gain control — normalise volume across speakers.

  Adjusts sample amplitude so quiet speakers are boosted and loud speakers
  are attenuated, targeting `target_rms_db` (typically -20 dB).
  `attack_ms` and `release_ms` control how fast the gain adapts.

  Returns `{normalised_pcm, new_state}` where state tracks the running gain.
  """
  @callback audio_agc(
              pcm :: [float()],
              target_rms_db :: float(),
              attack_ms :: float(),
              release_ms :: float(),
              state :: map()
            ) :: {[float()], map()}

  @doc """
  Generate comfort noise matching the spectral profile of recent silence.

  When voice activity stops, total silence sounds "dead" and jarring.
  This fills silence gaps with shaped noise at `level_db` below the
  speech level, using the `noise_profile` (spectral envelope from last
  detected noise floor).

  Returns comfort noise PCM samples.
  """
  @callback audio_comfort_noise(
              frame_length :: pos_integer(),
              level_db :: float(),
              noise_profile :: [float()]
            ) :: [float()]

  @doc """
  Spectral voice activity detection — uses FFT-based features.

  More accurate than energy-based VAD. Analyses spectral flatness,
  spectral centroid, and harmonic structure to distinguish speech
  from background noise (fans, typing, traffic).

  Returns `{is_speech, confidence, updated_state}` where confidence
  is 0.0-1.0 and state tracks running statistics.
  """
  @callback audio_spectral_vad(
              pcm :: [float()],
              sample_rate :: pos_integer(),
              state :: map()
            ) :: {boolean(), float(), map()}

  @doc """
  Apply perceptual weighting (A-weighting curve) to noise reduction.

  Shapes the noise reduction profile to match human hearing sensitivity.
  Frequencies we hear poorly (below 500 Hz, above 6 kHz) get less
  aggressive reduction, preserving naturalness. Frequencies in the
  speech band (1-4 kHz) get full reduction.

  Applied in the frequency domain (operates on FFT magnitudes).
  Returns weighted magnitude spectrum.
  """
  @callback audio_perceptual_weight(
              magnitudes :: [float()],
              sample_rate :: pos_integer()
            ) :: [float()]

  # ---------------------------------------------------------------------------
  # Crypto kernel — E2EE frame encryption, hash chains
  # ---------------------------------------------------------------------------

  @doc """
  Encrypt an audio frame using AES-256-GCM.

  Returns `{:ok, {ciphertext, iv, tag}}` or `{:error, reason}`.
  The IV is generated internally (12 bytes, random).
  """
  @callback crypto_encrypt_frame(
              plaintext :: binary(),
              key :: binary(),
              aad :: binary()
            ) :: {:ok, {binary(), binary(), binary()}} | {:error, term()}

  @doc """
  Decrypt an AES-256-GCM encrypted audio frame.

  Returns `{:ok, plaintext}` or `{:error, :decrypt_failed}`.
  """
  @callback crypto_decrypt_frame(
              ciphertext :: binary(),
              key :: binary(),
              iv :: binary(),
              tag :: binary(),
              aad :: binary()
            ) :: {:ok, binary()} | {:error, :decrypt_failed}

  @doc """
  Compute a SHA-256 hash chain link for Avow/Vext integrity.

  Given the previous hash and a payload, returns the next hash in the chain.
  """
  @callback crypto_hash_chain(
              prev_hash :: binary(),
              payload :: binary()
            ) :: binary()

  @doc """
  Derive an E2EE frame key from a shared secret using HKDF-SHA256.

  Returns a 32-byte key suitable for AES-256-GCM.
  """
  @callback crypto_derive_frame_key(
              shared_secret :: binary(),
              salt :: binary(),
              info :: binary()
            ) :: binary()

  # ---------------------------------------------------------------------------
  # I/O kernel — jitter buffer, packet loss concealment, adaptive bitrate
  # ---------------------------------------------------------------------------

  @doc """
  Insert a packet into a jitter buffer and return the next playable frame.

  The buffer reorders out-of-order packets and smooths timing jitter.
  `buffer_state` is an opaque map managed by the kernel.

  Returns `{:ok, frame | nil, updated_buffer}` — frame is nil if
  the buffer needs more packets before it can emit.
  """
  @callback io_jitter_buffer_push(
              buffer_state :: map(),
              packet :: binary(),
              sequence :: non_neg_integer(),
              timestamp :: non_neg_integer()
            ) :: {:ok, binary() | nil, map()}

  @doc """
  Generate a concealment frame for a lost packet.

  Uses the previous frame(s) to interpolate or repeat. The simplest
  approach is repetition; better implementations use pitch-period
  repetition or interpolation.

  Returns a synthetic PCM frame.
  """
  @callback io_conceal_loss(
              prev_frames :: [binary()],
              frame_size :: pos_integer()
            ) :: binary()

  @doc """
  Compute an adaptive bitrate recommendation based on network conditions.

  Takes packet loss ratio (0.0–1.0), round-trip time in ms, and
  current bitrate. Returns recommended bitrate in bits/sec.
  """
  @callback io_adaptive_bitrate(
              loss_ratio :: float(),
              rtt_ms :: non_neg_integer(),
              current_bitrate :: pos_integer()
            ) :: pos_integer()

  # ---------------------------------------------------------------------------
  # DSP kernel — FFT, convolution, mixing matrix
  # ---------------------------------------------------------------------------

  @doc """
  Compute the real FFT of a PCM signal.

  Returns complex frequency bins as `[{real, imag}, ...]`.
  Input length must be a power of 2.
  """
  @callback dsp_fft(
              signal :: [float()],
              size :: pos_integer()
            ) :: [{float(), float()}]

  @doc """
  Compute the inverse FFT, returning time-domain samples.
  """
  @callback dsp_ifft(
              spectrum :: [{float(), float()}],
              size :: pos_integer()
            ) :: [float()]

  @doc """
  Convolve two signals (e.g. audio + impulse response).

  Returns the convolution result. Length = len(a) + len(b) - 1.
  """
  @callback dsp_convolve(
              a :: [float()],
              b :: [float()]
            ) :: [float()]

  @doc """
  Apply a mixing matrix to multiple audio streams.

  `streams` is a list of PCM sample lists (one per source).
  `matrix` is a list of lists of floats — gains[output][input].
  Returns mixed output streams.
  """
  @callback dsp_mix(
              streams :: [[float()]],
              matrix :: [[float()]]
            ) :: [[float()]]

  # ---------------------------------------------------------------------------
  # Neural kernel — ML-based noise suppression
  # ---------------------------------------------------------------------------

  @doc """
  Apply ML-based noise suppression to a PCM frame.

  Removes non-speech sounds (keyboard clicks, fan noise, dog barking)
  while preserving speech. The `model_state` is opaque and maintained
  across frames for temporal continuity.

  Returns `{cleaned_pcm, updated_model_state}`.
  """
  @callback neural_denoise(
              pcm :: [float()],
              sample_rate :: pos_integer(),
              model_state :: term()
            ) :: {[float()], term()}

  @doc """
  Initialise the neural denoising model state.

  Called once per session. Returns the initial opaque model state.
  """
  @callback neural_init_model(
              sample_rate :: pos_integer()
            ) :: term()

  @doc """
  Classify the dominant noise type in a PCM frame.

  Returns one of: `:speech`, `:keyboard`, `:fan`, `:dog`, `:music`,
  `:silence`, `:unknown`, along with a confidence score (0.0–1.0).
  """
  @callback neural_classify_noise(
              pcm :: [float()],
              sample_rate :: pos_integer()
            ) :: {atom(), float()}

  # ---------------------------------------------------------------------------
  # Compression kernel — lossless compression for recording and audit export
  # ---------------------------------------------------------------------------

  @doc """
  Compress binary data using LZ4 (fast, low-latency).

  Intended for server-side recording: compress PCM or Opus frames before
  writing to disk. LZ4 adds ~5µs per frame — negligible vs I/O cost.

  Returns `{:ok, compressed_binary}` or `{:error, reason}`.
  """
  @callback compress_lz4(
              data :: binary()
            ) :: {:ok, binary()} | {:error, term()}

  @doc """
  Decompress an LZ4-compressed binary.

  Returns `{:ok, decompressed_binary}` or `{:error, :decompress_failed}`.
  """
  @callback decompress_lz4(
              compressed :: binary(),
              original_size :: pos_integer()
            ) :: {:ok, binary()} | {:error, :decompress_failed}

  @doc """
  Compress binary data using zstd (high ratio, higher latency).

  Intended for bulk audit log export: compress provenance chain JSON
  for archival or transfer. zstd at level 3 gives ~10-15x on JSON.

  `level` is the compression level (1–22, default 3).

  Returns `{:ok, compressed_binary}` or `{:error, reason}`.
  """
  @callback compress_zstd(
              data :: binary(),
              level :: pos_integer()
            ) :: {:ok, binary()} | {:error, term()}

  @doc """
  Decompress a zstd-compressed binary.

  Returns `{:ok, decompressed_binary}` or `{:error, :decompress_failed}`.
  """
  @callback decompress_zstd(
              compressed :: binary()
            ) :: {:ok, binary()} | {:error, :decompress_failed}

  @doc """
  Compress a list of PCM frames into a lossless recording archive.

  Uses FLAC-style linear prediction + Rice coding for perfect-fidelity
  audio archival at ~50-60% of raw PCM size. Each frame is independently
  seekable.

  Returns `{:ok, archive_binary}` with a header containing frame count,
  sample rate, channels, and frame offsets for random access.
  """
  @callback compress_audio_archive(
              frames :: [[float()]],
              sample_rate :: pos_integer(),
              channels :: 1 | 2
            ) :: {:ok, binary()} | {:error, term()}

  @doc """
  Decompress a single frame from a lossless audio archive by index.

  Returns `{:ok, pcm_floats}` or `{:error, :invalid_index}`.
  """
  @callback decompress_audio_frame(
              archive :: binary(),
              frame_index :: non_neg_integer()
            ) :: {:ok, [float()]} | {:error, :invalid_index | :decompress_failed}
end
