# SPDX-License-Identifier: MPL-2.0
#
# Mix task to benchmark coprocessor backends.
#
# Compares ElixirBackend vs ZigBackend across all kernel operations.
# Output is used to tune SmartBackend dispatch table.
#
# Usage:
#   mix bench.coprocessor

defmodule Mix.Tasks.Bench.Coprocessor do
  @moduledoc """
  Benchmark coprocessor backends (Elixir vs Zig).

  Runs each kernel operation multiple times and reports average
  execution time. Use results to update SmartBackend dispatch table.
  """

  use Mix.Task

  alias Burble.Coprocessor.ElixirBackend
  alias Burble.Coprocessor.ZigBackend

  @shortdoc "Benchmark coprocessor backends"

  @iterations 100
  @frame_size 960

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    zig_available = ZigBackend.available?()

    Mix.shell().info("=== Burble Coprocessor Benchmark ===")
    Mix.shell().info("Iterations: #{@iterations}")
    Mix.shell().info("Frame size: #{@frame_size} samples (20ms @ 48kHz)")
    Mix.shell().info("Zig NIF available: #{zig_available}")
    Mix.shell().info("")

    # Generate test data.
    pcm = for _ <- 1..@frame_size, do: :rand.uniform() * 2.0 - 1.0
    reference = for _ <- 1..@frame_size, do: :rand.uniform() * 2.0 - 1.0
    key = :crypto.strong_rand_bytes(32)
    aad = "test_peer_id"

    Mix.shell().info("--- Audio Kernel ---")
    bench("audio_encode", fn ->
      ElixirBackend.audio_encode(pcm, 48_000, 1, 32_000)
    end, if(zig_available, do: fn ->
      ZigBackend.audio_encode(pcm, 48_000, 1, 32_000)
    end))

    bench("audio_decode", fn ->
      {:ok, frame} = ElixirBackend.audio_encode(pcm, 48_000, 1, 32_000)
      ElixirBackend.audio_decode(frame, 48_000, 1)
    end, if(zig_available, do: fn ->
      {:ok, frame} = ZigBackend.audio_encode(pcm, 48_000, 1, 32_000)
      ZigBackend.audio_decode(frame, 48_000, 1)
    end))

    bench("audio_noise_gate", fn ->
      ElixirBackend.audio_noise_gate(pcm, -40.0)
    end, if(zig_available, do: fn ->
      ZigBackend.audio_noise_gate(pcm, -40.0)
    end))

    bench("audio_echo_cancel", fn ->
      ElixirBackend.audio_echo_cancel(pcm, reference, 128)
    end, if(zig_available, do: fn ->
      ZigBackend.audio_echo_cancel(pcm, reference, 128)
    end))

    Mix.shell().info("")
    Mix.shell().info("--- Crypto Kernel ---")
    bench("crypto_encrypt_frame", fn ->
      ElixirBackend.crypto_encrypt_frame("test_audio_data", key, aad)
    end, nil)

    bench("crypto_hash_chain", fn ->
      ElixirBackend.crypto_hash_chain(:crypto.strong_rand_bytes(32), "payload")
    end, nil)

    bench("crypto_derive_frame_key", fn ->
      ElixirBackend.crypto_derive_frame_key(key, "salt_value_here!", "info")
    end, nil)

    Mix.shell().info("")
    Mix.shell().info("--- DSP Kernel ---")
    # Use power-of-2 size for FFT.
    fft_signal = for _ <- 1..256, do: :rand.uniform() * 2.0 - 1.0

    bench("dsp_fft (256)", fn ->
      ElixirBackend.dsp_fft(fft_signal, 256)
    end, if(zig_available, do: fn ->
      ZigBackend.dsp_fft(fft_signal, 256)
    end))

    bench("dsp_convolve (64x32)", fn ->
      a = for _ <- 1..64, do: :rand.uniform()
      b = for _ <- 1..32, do: :rand.uniform()
      ElixirBackend.dsp_convolve(a, b)
    end, if(zig_available, do: fn ->
      a = for _ <- 1..64, do: :rand.uniform()
      b = for _ <- 1..32, do: :rand.uniform()
      ZigBackend.dsp_convolve(a, b)
    end))

    Mix.shell().info("")
    Mix.shell().info("--- Neural Kernel ---")
    bench("neural_denoise", fn ->
      state = ElixirBackend.neural_init_model(48_000)
      ElixirBackend.neural_denoise(pcm, 48_000, state)
    end, if(zig_available, do: fn ->
      state = ZigBackend.neural_init_model(48_000)
      ZigBackend.neural_denoise(pcm, 48_000, state)
    end))

    bench("neural_classify_noise", fn ->
      ElixirBackend.neural_classify_noise(pcm, 48_000)
    end, nil)

    Mix.shell().info("")
    Mix.shell().info("--- I/O Kernel ---")
    bench("io_jitter_buffer_push", fn ->
      ElixirBackend.io_jitter_buffer_push(%{}, "packet_data", 1, 1000)
    end, nil)

    bench("io_adaptive_bitrate", fn ->
      ElixirBackend.io_adaptive_bitrate(0.05, 100, 32_000)
    end, nil)

    Mix.shell().info("")
    Mix.shell().info("--- Compression Kernel ---")

    # Generate test data: 1KB of PCM-like binary (simulates one frame).
    pcm_binary = pcm |> Enum.map(fn s -> <<trunc(s * 32767)::signed-16>> end) |> IO.iodata_to_binary()

    bench("compress_lz4 (1.9KB)", fn ->
      ElixirBackend.compress_lz4(pcm_binary)
    end, if(zig_available, do: fn ->
      ZigBackend.compress_lz4(pcm_binary)
    end))

    bench("decompress_lz4", fn ->
      {:ok, compressed} = ElixirBackend.compress_lz4(pcm_binary)
      ElixirBackend.decompress_lz4(compressed, byte_size(pcm_binary))
    end, if(zig_available, do: fn ->
      {:ok, compressed} = ZigBackend.compress_lz4(pcm_binary)
      ZigBackend.decompress_lz4(compressed, byte_size(pcm_binary))
    end))

    # Generate 10KB of JSON-like audit data (simulates audit export).
    audit_json = Jason.encode!(for i <- 1..50, do: %{
      event_type: "login_success",
      user_id: "user_#{i}",
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      metadata: %{ip: "192.168.1.#{rem(i, 255)}"}
    })

    bench("compress_zstd (audit)", fn ->
      ElixirBackend.compress_zstd(audit_json, 3)
    end, nil)

    {:ok, compressed_audit} = ElixirBackend.compress_zstd(audit_json, 3)
    audit_ratio = Float.round(byte_size(audit_json) / byte_size(compressed_audit), 1)
    Mix.shell().info("    audit JSON: #{byte_size(audit_json)} bytes → #{byte_size(compressed_audit)} bytes (#{audit_ratio}x)")

    bench("compress_audio_archive", fn ->
      frames = for _ <- 1..10, do: pcm
      ElixirBackend.compress_audio_archive(frames, 48_000, 1)
    end, nil)

    {:ok, archive} = ElixirBackend.compress_audio_archive(
      (for _ <- 1..10, do: pcm), 48_000, 1
    )
    raw_audio = 10 * @frame_size * 4  # 10 frames * 960 samples * 4 bytes
    archive_ratio = Float.round(raw_audio / byte_size(archive), 1)
    Mix.shell().info("    audio archive: #{raw_audio} bytes → #{byte_size(archive)} bytes (#{archive_ratio}x)")

    Mix.shell().info("")
    Mix.shell().info("=== Done ===")
  end

  defp bench(name, elixir_fn, zig_fn) do
    elixir_us = measure(elixir_fn)

    if zig_fn do
      zig_us = measure(zig_fn)
      ratio = if zig_us > 0, do: Float.round(elixir_us / zig_us, 2), else: 0.0
      winner = if zig_us < elixir_us, do: "Zig", else: "Elixir"

      Mix.shell().info(
        "  #{String.pad_trailing(name, 24)} Elixir: #{format_us(elixir_us)}  Zig: #{format_us(zig_us)}  #{ratio}x  -> #{winner}"
      )
    else
      Mix.shell().info(
        "  #{String.pad_trailing(name, 24)} Elixir: #{format_us(elixir_us)}  (Zig: n/a)"
      )
    end
  end

  defp measure(func) do
    # Warm up.
    for _ <- 1..10, do: func.()

    # Measure.
    times =
      for _ <- 1..@iterations do
        {time, _result} = :timer.tc(func)
        time
      end

    # Average in microseconds.
    Enum.sum(times) / @iterations
  end

  defp format_us(us) when us < 1_000, do: "#{Float.round(us * 1.0, 1)}µs"
  defp format_us(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 2)}ms"
  defp format_us(us), do: "#{Float.round(us / 1_000_000, 2)}s"
end
