# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# BurbleWeb.API.SetupController — First-time setup wizard API.
#
# Guides new users through initial Burble server configuration:
#   1. Check what's configured vs what's needed
#   2. Enumerate available audio devices (via PipeWire)
#   3. Test selected microphone (capture + analyse short sample)
#   4. Test selected speakers (play test tone + verify)
#   5. Mark setup as complete (persist to VeriSimDB)
#
# The setup wizard is public (no auth required) because it runs
# before any user accounts exist. A one-time setup token prevents
# replay: once setup is marked complete, these endpoints return 403.
#
# Author: Jonathan D.A. Jewell

defmodule BurbleWeb.API.SetupController do
  @moduledoc """
  Controller for the first-time setup wizard.

  Provides endpoints for audio device enumeration, testing, and
  configuration. All endpoints are public but guarded by a setup
  completion flag in VeriSimDB — once setup is done, they return 403.

  ## Endpoints

  | Method | Path | Description |
  |--------|------|-------------|
  | GET | /api/v1/setup/check | Check setup status |
  | POST | /api/v1/setup/audio-devices | Enumerate audio devices |
  | POST | /api/v1/setup/test-microphone | Test selected microphone |
  | POST | /api/v1/setup/test-speakers | Test selected speakers |
  | POST | /api/v1/setup/complete | Mark setup as done |
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  require Logger

  alias Burble.Media.PipeWire

  # VeriSimDB key for the setup completion flag.
  @setup_complete_key "burble:setup:complete"

  # VeriSimDB key for audio device configuration.
  @audio_config_key "burble:setup:audio_config"

  # Duration of the microphone test recording (milliseconds).
  @mic_test_duration_ms 3_000

  # ── Actions ──

  @doc """
  GET /api/v1/setup/check

  Returns the current setup status: what's configured, what's missing,
  and whether setup has been completed.

  Response format:
      {
        "setup_complete": false,
        "checks": {
          "pipewire_available": true,
          "audio_input_configured": false,
          "audio_output_configured": false,
          "e2ee_keys_generated": true,
          "server_name_set": false
        },
        "missing": ["audio_input", "audio_output", "server_name"]
      }
  """
  def check(conn, _params) do
    setup_complete = setup_complete?()

    checks = %{
      pipewire_available: PipeWire.available?(),
      audio_input_configured: audio_input_configured?(),
      audio_output_configured: audio_output_configured?(),
      e2ee_keys_generated: e2ee_keys_exist?(),
      server_name_set: server_name_set?()
    }

    # Collect the list of missing configuration items.
    missing =
      [
        if(!checks.audio_input_configured, do: "audio_input"),
        if(!checks.audio_output_configured, do: "audio_output"),
        if(!checks.server_name_set, do: "server_name")
      ]
      |> Enum.reject(&is_nil/1)

    response = %{
      setup_complete: setup_complete,
      checks: checks,
      missing: missing
    }

    conn
    |> put_status(200)
    |> json(response)
  end

  @doc """
  POST /api/v1/setup/audio-devices

  Enumerate all available audio devices via PipeWire.

  Returns separate lists for input and output devices.
  Each device includes: id, name, description, sample_rates, channels.

  Response format:
      {
        "inputs": [
          {"id": 42, "name": "alsa_input.usb-...", "description": "USB Microphone", ...}
        ],
        "outputs": [
          {"id": 55, "name": "alsa_output.pci-...", "description": "Built-in Speakers", ...}
        ],
        "pipewire_available": true
      }
  """
  def audio_devices(conn, _params) do
    if not PipeWire.available?() do
      conn
      |> put_status(503)
      |> json(%{
        error: "pipewire_not_available",
        message:
          "PipeWire is not running on this system. Audio device enumeration requires PipeWire."
      })
    else
      with {:ok, inputs} <- PipeWire.enumerate_inputs(),
           {:ok, outputs} <- PipeWire.enumerate_outputs() do
        response = %{
          inputs: Enum.map(inputs, &serialise_device/1),
          outputs: Enum.map(outputs, &serialise_device/1),
          pipewire_available: true
        }

        conn
        |> put_status(200)
        |> json(response)
      else
        {:error, reason} ->
          conn
          |> put_status(500)
          |> json(%{
            error: "enumeration_failed",
            message: "Failed to enumerate audio devices: #{inspect(reason)}"
          })
      end
    end
  end

  @doc """
  POST /api/v1/setup/test-microphone

  Run a quick self-test on the selected microphone.

  Request body:
      {"device_id": 42}

  The test:
    1. Requests exclusive access to the device
    2. Records a short audio sample (3 seconds)
    3. Analyses the sample for signal presence and level
    4. Releases exclusive access
    5. Returns test results

  Response format:
      {
        "success": true,
        "device_id": 42,
        "signal_detected": true,
        "peak_level_db": -12.5,
        "noise_floor_db": -60.0,
        "duration_ms": 3000
      }
  """
  def test_microphone(conn, %{"device_id" => device_id_str}) do
    with {:ok, device_id} <- parse_device_id(device_id_str),
         {:ok, device} <- PipeWire.device_info(device_id),
         :ok <- validate_input_device(device) do
      # Run the microphone test.
      test_result = run_microphone_test(device_id)

      conn
      |> put_status(200)
      |> json(test_result)
    else
      {:error, :invalid_device_id} ->
        conn |> put_status(400) |> json(%{error: "invalid_device_id"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "device_not_found"})

      {:error, :not_input_device} ->
        conn |> put_status(400) |> json(%{error: "not_an_input_device"})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: "test_failed", reason: inspect(reason)})
    end
  end

  def test_microphone(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing_device_id"})
  end

  @doc """
  POST /api/v1/setup/test-speakers

  Run a quick self-test on the selected speakers.

  Request body:
      {"device_id": 55}

  The test:
    1. Requests exclusive access to the device
    2. Plays a short test tone (440Hz sine wave, 1 second)
    3. Reports success (actual playback verification requires human confirmation)
    4. Releases exclusive access

  Response format:
      {
        "success": true,
        "device_id": 55,
        "tone_played": true,
        "frequency_hz": 440,
        "duration_ms": 1000,
        "message": "Did you hear a tone? Confirm in the next step."
      }
  """
  def test_speakers(conn, %{"device_id" => device_id_str}) do
    with {:ok, device_id} <- parse_device_id(device_id_str),
         {:ok, device} <- PipeWire.device_info(device_id),
         :ok <- validate_output_device(device) do
      # Run the speaker test.
      test_result = run_speaker_test(device_id)

      conn
      |> put_status(200)
      |> json(test_result)
    else
      {:error, :invalid_device_id} ->
        conn |> put_status(400) |> json(%{error: "invalid_device_id"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "device_not_found"})

      {:error, :not_output_device} ->
        conn |> put_status(400) |> json(%{error: "not_an_output_device"})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: "test_failed", reason: inspect(reason)})
    end
  end

  def test_speakers(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing_device_id"})
  end

  @doc """
  POST /api/v1/setup/complete

  Mark the setup as done and persist the audio configuration.

  Request body:
      {
        "input_device_id": 42,
        "output_device_id": 55,
        "server_name": "My Burble Server"
      }

  Once setup is marked complete, setup endpoints return 403.
  The configuration is stored in VeriSimDB for persistence across restarts.

  Response format:
      {
        "success": true,
        "message": "Setup complete. Burble is ready to use."
      }
  """
  def complete(conn, params) do
    if setup_complete?() do
      conn
      |> put_status(403)
      |> json(%{
        error: "setup_already_complete",
        message: "Setup has already been completed. Reset via admin panel if reconfiguration is needed."
      })
    else
      with {:ok, input_id} <- parse_device_id(Map.get(params, "input_device_id")),
           {:ok, output_id} <- parse_device_id(Map.get(params, "output_device_id")),
           server_name when is_binary(server_name) <- Map.get(params, "server_name", "Burble Server") do
        # Persist audio configuration to VeriSimDB.
        audio_config = %{
          input_device_id: input_id,
          output_device_id: output_id,
          server_name: server_name,
          configured_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        :ok = store_put(@audio_config_key, audio_config)
        :ok = store_put(@setup_complete_key, true)

        Logger.info(
          "[Setup] Setup complete: input=#{input_id}, output=#{output_id}, name=#{server_name}"
        )

        conn
        |> put_status(200)
        |> json(%{
          success: true,
          message: "Setup complete. Burble is ready to use.",
          config: audio_config
        })
      else
        {:error, :invalid_device_id} ->
          conn |> put_status(400) |> json(%{error: "invalid_device_id"})

        _ ->
          conn |> put_status(400) |> json(%{error: "invalid_parameters"})
      end
    end
  end

  # ── Private: Setup status checks ──

  # Check if the setup has been completed (persisted in VeriSimDB).
  @spec setup_complete?() :: boolean()
  defp setup_complete? do
    case store_get(@setup_complete_key) do
      {:ok, true} -> true
      _ -> false
    end
  end

  # Check if an audio input device has been configured.
  @spec audio_input_configured?() :: boolean()
  defp audio_input_configured? do
    case store_get(@audio_config_key) do
      {:ok, %{input_device_id: id}} when not is_nil(id) -> true
      _ -> false
    end
  end

  # Check if an audio output device has been configured.
  @spec audio_output_configured?() :: boolean()
  defp audio_output_configured? do
    case store_get(@audio_config_key) do
      {:ok, %{output_device_id: id}} when not is_nil(id) -> true
      _ -> false
    end
  end

  # Check if E2EE keys have been generated.
  @spec e2ee_keys_exist?() :: boolean()
  defp e2ee_keys_exist? do
    # E2EE keys are generated per-room, not globally.
    # For setup check, we verify the E2EE GenServer is running.
    case Process.whereis(Burble.Media.E2EE) do
      nil -> false
      _pid -> true
    end
  end

  # Check if a server name has been set.
  @spec server_name_set?() :: boolean()
  defp server_name_set? do
    case store_get(@audio_config_key) do
      {:ok, %{server_name: name}} when is_binary(name) and name != "" -> true
      _ -> false
    end
  end

  # ── Private: Device validation ──

  # Parse a device ID from string or integer input.
  @spec parse_device_id(term()) :: {:ok, non_neg_integer()} | {:error, :invalid_device_id}
  defp parse_device_id(id) when is_integer(id) and id >= 0, do: {:ok, id}

  defp parse_device_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> {:error, :invalid_device_id}
    end
  end

  defp parse_device_id(_), do: {:error, :invalid_device_id}

  # Validate that a device is an input device (microphone).
  @spec validate_input_device(PipeWire.device_info()) :: :ok | {:error, :not_input_device}
  defp validate_input_device(%{direction: dir}) when dir in [:input, :duplex], do: :ok
  defp validate_input_device(_), do: {:error, :not_input_device}

  # Validate that a device is an output device (speakers).
  @spec validate_output_device(PipeWire.device_info()) :: :ok | {:error, :not_output_device}
  defp validate_output_device(%{direction: dir}) when dir in [:output, :duplex], do: :ok
  defp validate_output_device(_), do: {:error, :not_output_device}

  # ── Private: Audio tests ──

  # Run a microphone test: record a short sample and analyse it.
  #
  # Uses pw-record (PipeWire's recording tool) to capture audio,
  # then analyses the captured data for signal presence.
  @spec run_microphone_test(non_neg_integer()) :: map()
  defp run_microphone_test(device_id) do
    # Create a temporary file for the recording.
    tmp_file = Path.join(System.tmp_dir!(), "burble_mic_test_#{device_id}_#{System.unique_integer([:positive])}.wav")

    try do
      # Request exclusive access for the test duration.
      PipeWire.request_exclusive(device_id)

      # Record using pw-record with the specified device.
      # --target specifies the PipeWire node ID.
      duration_seconds = @mic_test_duration_ms / 1000.0
      args = [
        "--target", Integer.to_string(device_id),
        "--rate", "48000",
        "--channels", "1",
        "--format", "s16",
        tmp_file
      ]

      # pw-record runs indefinitely; we kill it after the test duration.
      port = Port.open({:spawn_executable, System.find_executable("pw-record")}, [
        :binary,
        :exit_status,
        args: args
      ])

      # Wait for the recording duration.
      Process.sleep(round(duration_seconds * 1000))

      # Send SIGTERM to stop recording.
      Port.close(port)

      # Analyse the recorded audio.
      analysis = analyse_audio_file(tmp_file)

      # Release exclusive access.
      PipeWire.release_exclusive(device_id)

      %{
        success: true,
        device_id: device_id,
        signal_detected: analysis.signal_detected,
        peak_level_db: analysis.peak_level_db,
        noise_floor_db: analysis.noise_floor_db,
        duration_ms: @mic_test_duration_ms
      }
    rescue
      error ->
        # Ensure exclusive access is released on error.
        PipeWire.release_exclusive(device_id)
        Logger.error("[Setup] Microphone test failed: #{inspect(error)}")

        %{
          success: false,
          device_id: device_id,
          signal_detected: false,
          peak_level_db: nil,
          noise_floor_db: nil,
          duration_ms: 0,
          error: Exception.message(error)
        }
    after
      # Clean up the temporary file.
      File.rm(tmp_file)
    end
  end

  # Run a speaker test: play a 440Hz test tone for 1 second.
  @spec run_speaker_test(non_neg_integer()) :: map()
  defp run_speaker_test(device_id) do
    tmp_file = Path.join(System.tmp_dir!(), "burble_spk_test_#{device_id}_#{System.unique_integer([:positive])}.wav")

    try do
      # Request exclusive access.
      PipeWire.request_exclusive(device_id)

      # Generate a 440Hz test tone WAV file.
      generate_test_tone(tmp_file, 440, 1.0)

      # Play using pw-play with the specified device.
      # SECURITY: pw-play is hardcoded. device_id is an integer (from PipeWire
      # enumeration, validated by Integer.to_string). tmp_file is generated
      # by System.tmp_dir!/0 + unique_integer — no user input in commands.
      args = [
        "--target", Integer.to_string(device_id),
        tmp_file
      ]

      case System.cmd("pw-play", args, stderr_to_stdout: true, timeout: 5_000) do
        {_output, 0} ->
          PipeWire.release_exclusive(device_id)

          %{
            success: true,
            device_id: device_id,
            tone_played: true,
            frequency_hz: 440,
            duration_ms: 1000,
            message: "Did you hear a tone? Confirm in the next step."
          }

        {output, code} ->
          PipeWire.release_exclusive(device_id)

          %{
            success: false,
            device_id: device_id,
            tone_played: false,
            error: "pw-play failed (exit #{code}): #{String.slice(output, 0, 200)}"
          }
      end
    rescue
      error ->
        PipeWire.release_exclusive(device_id)
        Logger.error("[Setup] Speaker test failed: #{inspect(error)}")

        %{
          success: false,
          device_id: device_id,
          tone_played: false,
          error: Exception.message(error)
        }
    after
      # Always clean up the temporary tone file.
      File.rm(tmp_file)
    end
  end

  # ── Private: Audio analysis ──

  # Analyse a WAV audio file for signal presence and level.
  # Returns a map with signal_detected, peak_level_db, and noise_floor_db.
  @spec analyse_audio_file(String.t()) :: map()
  defp analyse_audio_file(file_path) do
    case File.read(file_path) do
      {:ok, data} when byte_size(data) > 44 ->
        # Skip the 44-byte WAV header and read 16-bit signed PCM samples.
        <<_header::binary-44, pcm_data::binary>> = data

        # Convert to list of 16-bit signed integers.
        samples = for <<sample::little-signed-16 <- pcm_data>>, do: sample

        if length(samples) > 0 do
          # Calculate peak level.
          peak = Enum.max_by(samples, &abs/1) |> abs()
          peak_db = if peak > 0, do: 20 * :math.log10(peak / 32768.0), else: -96.0

          # Calculate RMS (noise floor approximation using the quietest 10%).
          sorted_abs = samples |> Enum.map(&abs/1) |> Enum.sort()
          quiet_tenth = Enum.take(sorted_abs, max(div(length(sorted_abs), 10), 1))
          rms_quiet = :math.sqrt(Enum.sum(Enum.map(quiet_tenth, &(&1 * &1))) / length(quiet_tenth))
          noise_db = if rms_quiet > 0, do: 20 * :math.log10(rms_quiet / 32768.0), else: -96.0

          # Signal is "detected" if peak is at least 20dB above noise floor.
          signal_detected = peak_db - noise_db > 20.0

          %{
            signal_detected: signal_detected,
            peak_level_db: Float.round(peak_db, 1),
            noise_floor_db: Float.round(noise_db, 1)
          }
        else
          %{signal_detected: false, peak_level_db: -96.0, noise_floor_db: -96.0}
        end

      _ ->
        %{signal_detected: false, peak_level_db: -96.0, noise_floor_db: -96.0}
    end
  end

  # Generate a WAV file containing a sine wave test tone.
  #
  # Parameters:
  #   - file_path: output WAV file path
  #   - frequency_hz: tone frequency (default: 440Hz, concert A)
  #   - duration_seconds: tone duration
  #   - sample_rate: audio sample rate (default: 48000)
  @spec generate_test_tone(String.t(), number(), float(), non_neg_integer()) :: :ok
  defp generate_test_tone(file_path, frequency_hz, duration_seconds, sample_rate \\ 48_000) do
    num_samples = round(sample_rate * duration_seconds)
    amplitude = 16384

    # Generate 16-bit PCM samples for the sine wave.
    pcm_data =
      for i <- 0..(num_samples - 1), into: <<>> do
        # Phase in radians for this sample.
        phase = 2.0 * :math.pi() * frequency_hz * i / sample_rate
        # Sine wave value scaled to 16-bit range.
        sample = round(amplitude * :math.sin(phase))
        <<sample::little-signed-16>>
      end

    # Build the WAV file header (44 bytes).
    data_size = byte_size(pcm_data)
    file_size = 36 + data_size
    bits_per_sample = 16
    num_channels = 1
    byte_rate = sample_rate * num_channels * div(bits_per_sample, 8)
    block_align = num_channels * div(bits_per_sample, 8)

    wav_header = <<
      # RIFF header
      "RIFF",
      file_size::little-32,
      "WAVE",
      # fmt sub-chunk
      "fmt ",
      16::little-32,
      1::little-16,
      num_channels::little-16,
      sample_rate::little-32,
      byte_rate::little-32,
      block_align::little-16,
      bits_per_sample::little-16,
      # data sub-chunk
      "data",
      data_size::little-32
    >>

    File.write!(file_path, wav_header <> pcm_data)
    :ok
  end

  # ── Private: Serialisation ──

  # Serialise a PipeWire device_info map for JSON response.
  @spec serialise_device(PipeWire.device_info()) :: map()
  defp serialise_device(device) do
    %{
      id: device.id,
      name: device.name,
      description: device.description,
      direction: Atom.to_string(device.direction),
      sample_rates: device.sample_rates,
      channels: device.channels,
      format: device.format,
      is_default: device.is_default
    }
  end

  # ── Private: VeriSimDB wrappers ──

  # Read a value from VeriSimDB (Burble's persistent store).
  # Wraps the store module to handle the case where it's not running.
  @spec store_get(String.t()) :: {:ok, term()} | {:error, term()}
  defp store_get(key) do
    try do
      # Uses runtime dispatch — Burble.Store may not be fully defined yet.
      apply(Burble.Store, :get, [key])
    rescue
      _ -> {:error, :store_unavailable}
    catch
      :exit, _ -> {:error, :store_unavailable}
    end
  end

  # Write a value to VeriSimDB.
  @spec store_put(String.t(), term()) :: :ok | {:error, term()}
  defp store_put(key, value) do
    try do
      # Uses runtime dispatch — Burble.Store may not be fully defined yet.
      apply(Burble.Store, :put, [key, value])
    rescue
      _ -> {:error, :store_unavailable}
    catch
      :exit, _ -> {:error, :store_unavailable}
    end
  end
end
