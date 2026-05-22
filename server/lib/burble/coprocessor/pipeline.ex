# SPDX-License-Identifier: MPL-2.0
#
# Burble.Coprocessor.Pipeline — Audio frame processing pipeline.
#
# Chains coprocessor kernels into an ordered pipeline that processes
# every audio frame before forwarding (outbound) or after receiving
# (inbound). The pipeline order matters:
#
# Outbound (capture → server):
#   1. Neural denoise (remove keyboard/fan/dog noise)
#   2. Audio noise gate (silence residual noise below threshold)
#   3. Audio echo cancel (remove speaker feedback)
#   4. Audio encode (PCM → Opus)
#   5. Crypto encrypt (E2EE frame encryption)
#   6. I/O adaptive bitrate (adjust encoding quality)
#
# Inbound (server → playback):
#   1. I/O jitter buffer (reorder, smooth timing)
#   2. I/O packet loss concealment (fill gaps)
#   3. Crypto decrypt (E2EE frame decryption)
#   4. Audio decode (Opus → PCM)
#   5. DSP mix (combine multiple speaker streams)
#
# The pipeline is a GenServer per peer session. Each peer gets its own
# pipeline instance with independent state (jitter buffer, neural model,
# echo cancellation filter).

defmodule Burble.Coprocessor.Pipeline do
  @moduledoc """
  Per-peer audio processing pipeline using coprocessor kernels.

  Manages the ordered chain of kernel operations for both inbound
  and outbound audio frames. Each pipeline maintains per-peer state
  (jitter buffer, denoiser model, echo cancellation filter weights).

  ## Usage

      {:ok, pid} = Pipeline.start_link(peer_id: "user_123", e2ee_key: key)
      {:ok, opus_frame} = Pipeline.process_outbound(pid, pcm_samples)
      {:ok, pcm_samples} = Pipeline.process_inbound(pid, opus_frame)
  """

  use GenServer, restart: :temporary
  require Logger

  alias Burble.Coprocessor.SmartBackend, as: Backend

  @type pipeline_config :: %{
          sample_rate: pos_integer(),
          channels: 1 | 2,
          bitrate: pos_integer(),
          noise_gate_db: float(),
          echo_cancel_taps: pos_integer(),
          e2ee_enabled: boolean(),
          neural_denoise: boolean()
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Start a pipeline for a peer session."
  def start_link(opts) do
    peer_id = Keyword.fetch!(opts, :peer_id)
    GenServer.start_link(__MODULE__, opts, name: via(peer_id))
  end

  @doc """
  Process an outbound audio frame (capture → server).

  Takes raw PCM samples, runs the outbound kernel chain, and returns
  the encoded (and optionally encrypted) frame ready for sending.
  """
  @spec process_outbound(pid() | GenServer.name(), [float()]) ::
          {:ok, binary()} | {:error, term()}
  def process_outbound(pipeline, pcm_samples) do
    GenServer.call(pipeline, {:outbound, pcm_samples})
  end

  @doc """
  Process an inbound audio frame (server → playback).

  Takes an encoded (and optionally encrypted) frame, runs the inbound
  kernel chain, and returns decoded PCM samples ready for playback.
  """
  @spec process_inbound(pid() | GenServer.name(), binary(), non_neg_integer(), non_neg_integer()) ::
          {:ok, [float()] | nil} | {:error, term()}
  def process_inbound(pipeline, frame, sequence, timestamp) do
    GenServer.call(pipeline, {:inbound, frame, sequence, timestamp})
  end

  @doc """
  Mix multiple decoded streams into output channels.

  Takes a list of PCM sample lists (one per speaker) and a gain matrix,
  returns mixed output streams.
  """
  @spec mix_streams(pid() | GenServer.name(), [[float()]], [[float()]]) :: {:ok, [[float()]]}
  def mix_streams(pipeline, streams, matrix) do
    GenServer.call(pipeline, {:mix, streams, matrix})
  end

  @doc "Get pipeline health metrics."
  @spec health(pid() | GenServer.name()) :: {:ok, map()}
  def health(pipeline) do
    GenServer.call(pipeline, :health)
  end

  @doc "Stop the pipeline."
  def stop(pipeline) do
    GenServer.stop(pipeline, :normal)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    peer_id = Keyword.fetch!(opts, :peer_id)
    e2ee_key = Keyword.get(opts, :e2ee_key)
    config = Keyword.get(opts, :config, default_config())

    # Initialise per-kernel state.
    neural_state = if config.neural_denoise, do: Backend.neural_init_model(config.sample_rate), else: nil

    state = %{
      peer_id: peer_id,
      config: config,
      e2ee_key: e2ee_key,
      # Per-kernel state
      neural_state: neural_state,
      jitter_buffer: %{},
      prev_frames: [],
      # Playback reference for echo cancellation — populated from decoded
      # inbound frames so the echo canceller has a real speaker signal to
      # subtract from the capture. When this is empty (no inbound audio yet),
      # echo cancel runs against silence (harmless no-op until first frame).
      playback_ref: [],
      # Silence counter: frames since last non-nil inbound. Drives comfort
      # noise injection so peers don't hear dead air when a speaker pauses.
      silence_frames: 0,
      # Last RTP timestamp received from the network — populated via
      # record_rtp_timestamp/2 when peer.ex extracts it from incoming packets.
      # Used by Phase 4 PTP correlation to map RTP clock → wall clock.
      last_rtp_ts: 0,
      # Metrics
      frames_processed: 0,
      frames_dropped: 0,
      current_bitrate: config.bitrate,
      started_at: DateTime.utc_now()
    }

    Logger.info("[Pipeline] Started for peer #{peer_id} (backend: #{Backend.backend_type()})")
    {:ok, state}
  end

  @impl true
  def handle_call({:outbound, pcm}, _from, state) do
    config = state.config

    # Step 1: Neural denoise (if enabled).
    {pcm, neural_state} =
      if config.neural_denoise and state.neural_state do
        Backend.neural_denoise(pcm, config.sample_rate, state.neural_state)
      else
        {pcm, state.neural_state}
      end

    # Step 2: Noise gate.
    pcm = Backend.audio_noise_gate(pcm, config.noise_gate_db)

    # Step 3: Echo cancellation — use real playback reference when available.
    reference =
      case state.playback_ref do
        ref when is_list(ref) and length(ref) == length(pcm) -> ref
        _ -> List.duplicate(0.0, length(pcm))
      end

    pcm = Backend.audio_echo_cancel(pcm, reference, config.echo_cancel_taps)

    # Step 4: Encode.
    case Backend.audio_encode(pcm, config.sample_rate, config.channels, state.current_bitrate) do
      {:ok, encoded} ->
        # Step 5: Encrypt (if E2EE).
        frame =
          if state.e2ee_key do
            aad = state.peer_id
            case Backend.crypto_encrypt_frame(encoded, state.e2ee_key, aad) do
              {:ok, {ct, iv, tag}} -> iv <> tag <> ct
              {:error, _} -> encoded
            end
          else
            encoded
          end

        new_state = %{state |
          neural_state: neural_state,
          frames_processed: state.frames_processed + 1
        }

        {:reply, {:ok, frame}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:inbound, frame, sequence, timestamp}, _from, state) do
    config = state.config

    # Step 1: Jitter buffer.
    {:ok, buffered, new_jitter} =
      Backend.io_jitter_buffer_push(state.jitter_buffer, frame, sequence, timestamp)

    state = %{state | jitter_buffer: new_jitter}

    case buffered do
      nil ->
        # Buffer not ready to emit — need more packets. If we've been
        # silent for enough frames, inject comfort noise so the peer
        # doesn't hear dead air. This is a server-side injection only;
        # the client's own comfort noise generator handles the local side.
        silence_frames = state.silence_frames + 1

        if silence_frames >= 3 do
          comfort = Backend.audio_comfort_noise(960, -60.0, %{})
          {:reply, {:ok, comfort}, %{state | silence_frames: silence_frames}}
        else
          {:reply, {:ok, nil}, %{state | silence_frames: silence_frames}}
        end

      ready_frame ->
        # Step 2: Check for loss (gap in sequence numbers handled by jitter buffer).
        # Step 3: Decrypt (if E2EE).
        decrypted =
          if state.e2ee_key do
            case ready_frame do
              <<iv::binary-12, tag::binary-16, ct::binary>> ->
                aad = state.peer_id
                case Backend.crypto_decrypt_frame(ct, state.e2ee_key, iv, tag, aad) do
                  {:ok, plaintext} -> plaintext
                  {:error, _} -> ready_frame
                end

              _ ->
                ready_frame
            end
          else
            ready_frame
          end

        # Step 4: Decode.
        case Backend.audio_decode(decrypted, config.sample_rate, config.channels) do
          {:ok, pcm} ->
            new_state = %{state |
              frames_processed: state.frames_processed + 1,
              prev_frames: [ready_frame | Enum.take(state.prev_frames, 2)],
              playback_ref: pcm,
              silence_frames: 0
            }

            {:reply, {:ok, pcm}, new_state}

          {:error, _} ->
            # Decode failed — attempt packet loss concealment.
            concealed = Backend.io_conceal_loss(state.prev_frames, 960)

            new_state = %{state |
              frames_dropped: state.frames_dropped + 1,
              prev_frames: [concealed | Enum.take(state.prev_frames, 2)]
            }

            {:reply, {:ok, concealed}, new_state}
        end
    end
  end

  @impl true
  def handle_call({:mix, streams, matrix}, _from, state) do
    mixed = Backend.dsp_mix(streams, matrix)
    {:reply, {:ok, mixed}, state}
  end

  @impl true
  def handle_call(:health, _from, state) do
    health = %{
      peer_id: state.peer_id,
      backend: Backend.backend_type(),
      zig_available: Burble.Coprocessor.ZigBackend.available?(),
      frames_processed: state.frames_processed,
      frames_dropped: state.frames_dropped,
      drop_rate: safe_div(state.frames_dropped, state.frames_processed),
      current_bitrate: state.current_bitrate,
      e2ee: state.e2ee_key != nil,
      neural_denoise: state.config.neural_denoise,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at)
    }

    {:reply, {:ok, health}, state}
  end

  # ---------------------------------------------------------------------------
  # RTP timestamp tracking (Phase 4 PTP precursor)
  # ---------------------------------------------------------------------------

  @doc """
  Record the latest RTP timestamp received from the network.

  Called by `Burble.Media.Peer` each time an RTP packet arrives so the
  pipeline knows the sender's RTP clock position. Phase 4 will correlate
  this against the PTP hardware clock to derive end-to-end latency and
  enable multi-node playout alignment.
  """
  def record_rtp_timestamp(pipeline, rtp_ts) do
    GenServer.cast(pipeline, {:rtp_timestamp, rtp_ts})
  end

  @impl true
  def handle_cast({:rtp_timestamp, rtp_ts}, state) do
    {:noreply, %{state | last_rtp_ts: rtp_ts}}
  end

  # ---------------------------------------------------------------------------
  # Bitrate adaptation (REMB feedback)
  # ---------------------------------------------------------------------------

  @doc """
  Update the encoding bitrate based on REMB (Receiver Estimated Maximum
  Bitrate) feedback from the peer's PeerConnection.

  Called by `Burble.Media.Peer` when it receives an RTCP REMB packet
  indicating the remote client's available bandwidth. The pipeline adjusts
  its PCM framing bitrate accordingly (primarily affects self-test and
  archive paths; live SFU forwarding is opaque Opus which the browser
  adjusts independently).
  """
  def update_bitrate(pipeline, loss_ratio, rtt_ms) do
    GenServer.cast(pipeline, {:update_bitrate, loss_ratio, rtt_ms})
  end

  @impl true
  def handle_cast({:update_bitrate, loss_ratio, rtt_ms}, state) do
    new_bitrate = Backend.io_adaptive_bitrate(loss_ratio, rtt_ms, state.current_bitrate)

    if new_bitrate != state.current_bitrate do
      Logger.info("[Pipeline] Bitrate #{state.current_bitrate} → #{new_bitrate} " <>
                  "(loss=#{Float.round(loss_ratio * 100, 1)}%, rtt=#{rtt_ms}ms)")
    end

    {:noreply, %{state | current_bitrate: new_bitrate}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp default_config do
    %{
      sample_rate: 48_000,
      channels: 1,
      bitrate: 32_000,
      noise_gate_db: -40.0,
      echo_cancel_taps: 128,
      e2ee_enabled: false,
      neural_denoise: true
    }
  end

  defp via(peer_id) do
    {:via, Registry, {Burble.CoprocessorRegistry, peer_id}}
  end

  defp safe_div(_num, 0), do: 0.0
  defp safe_div(num, den), do: num / den
end
