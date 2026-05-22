# SPDX-License-Identifier: MPL-2.0
#
# Burble Coprocessor Benchmark — SIMD vs Elixir.
#
# Measures the processing time for audio kernels (encode, noise gate, dsp)
# under high-load conditions (simulating 500+ participants).

defmodule Burble.Coprocessor.BenchmarkTest do
  use ExUnit.Case, async: false
  alias Burble.Coprocessor.{ZigBackend, ElixirBackend}

  @participants 500
  @frame_size 960 # 20ms at 48kHz

  setup_all do
    # Ensure Zig NIFs are available
    if not ZigBackend.available?() do
      IO.warn("Zig NIFs not available! Benchmarking Elixir fallback only.")
    end
    :ok
  end

  describe "Audio Kernel Benchmarks" do
    test "PCM Encoding speedup" do
      pcm = for _ <- 1..@frame_size, do: :rand.uniform() * 2.0 - 1.0
      
      {elixir_time, _} = :timer.tc(fn ->
        Enum.each(1..@participants, fn _ ->
          ElixirBackend.audio_encode(pcm, 48000, 1, 64000)
        end)
      end)

      if ZigBackend.available?() do
        {zig_time, _} = :timer.tc(fn ->
          Enum.each(1..@participants, fn _ ->
            ZigBackend.audio_encode(pcm, 48000, 1, 64000)
          end)
        end)

        speedup = elixir_time / zig_time
        IO.puts("\n[Benchmark] PCM Encode (500 frames): Elixir=#{elixir_time}µs, Zig=#{zig_time}µs, Speedup=#{Float.round(speedup, 2)}x")
        assert zig_time < elixir_time
      end
    end

    test "Noise Gate SIMD speedup" do
      pcm = for _ <- 1..@frame_size, do: :rand.uniform() * 0.05 - 0.025
      
      {elixir_time, _} = :timer.tc(fn ->
        Enum.each(1..@participants, fn _ ->
          ElixirBackend.audio_noise_gate(pcm, -30.0)
        end)
      end)

      if ZigBackend.available?() do
        {zig_time, _} = :timer.tc(fn ->
          Enum.each(1..@participants, fn _ ->
            ZigBackend.audio_noise_gate(pcm, -30.0)
          end)
        end)

        speedup = elixir_time / zig_time
        IO.puts("[Benchmark] Noise Gate (500 frames): Elixir=#{elixir_time}µs, Zig=#{zig_time}µs, Speedup=#{Float.round(speedup, 2)}x")
        assert zig_time < elixir_time
      end
    end
  end

  describe "DSP Kernel Benchmarks" do
    test "FFT 1024-point speedup" do
      size = 1024
      signal = for _ <- 1..size, do: :rand.uniform()
      
      {elixir_time, _} = :timer.tc(fn ->
        Enum.each(1..100, fn _ ->
          ElixirBackend.dsp_fft(signal, size)
        end)
      end)

      if ZigBackend.available?() do
        {zig_time, _} = :timer.tc(fn ->
          Enum.each(1..100, fn _ ->
            ZigBackend.dsp_fft(signal, size)
          end)
        end)

        speedup = elixir_time / zig_time
        IO.puts("[Benchmark] FFT (100 runs): Elixir=#{elixir_time}µs, Zig=#{zig_time}µs, Speedup=#{Float.round(speedup, 2)}x")
        assert zig_time < elixir_time
      end
    end
  end
end
