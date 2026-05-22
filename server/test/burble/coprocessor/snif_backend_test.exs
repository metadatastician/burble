# SPDX-License-Identifier: MPL-2.0
defmodule Burble.Coprocessor.SNIFBackendTest do
  use ExUnit.Case, async: true
  alias Burble.Coprocessor.{SNIFBackend, ZigBackend, ElixirBackend}

  test "backend_type returns :snif" do
      assert SNIFBackend.backend_type() == :snif
    end

    test "available? returns false when WASM file missing" do
      # No WASM file and no :wasmex NIF in the test env, so the backend
      # must report unavailable (see ADR-0007 / PR #46).
      
      # Mock the path check
      assert SNIFBackend.available?() == false
    end

    describe "FFT operations" do
      test "dsp_fft falls back to ZigBackend when SNIF unavailable" do
        signal = [1.0, 0.0, -1.0, 0.0]  # Simple 4-point signal
        size = 4
        
        # Since SNIF is unavailable, should fallback to ZigBackend
        result = SNIFBackend.dsp_fft(signal, size)
        
        # Should get valid FFT result (format: [{real, imag}, ...])
        assert result |> is_list()
        assert length(result) == size
        assert hd(result) |> tuple_size() == 2
      end

      test "dsp_ifft falls back to ZigBackend when SNIF unavailable" do
        # Create simple spectrum: DC component only
        spectrum = [{1.0, 0.0}, {0.0, 0.0}, {0.0, 0.0}, {0.0, 0.0}]
        size = 4
        
        result = SNIFBackend.dsp_ifft(spectrum, size)
        
        # Should get valid time-domain signal
        assert result |> is_list()
        assert length(result) == size
      end
    end

    describe "other operations" do
      test "audio operations fallback to ZigBackend" do
        pcm = [0.1, -0.1, 0.2, -0.2]
        
        # These should all fallback to ZigBackend
        assert SNIFBackend.audio_noise_gate(pcm, -40.0) |> is_list()
        assert SNIFBackend.audio_encode(pcm, 48000, 1, 32000) |> tuple_size() == 2
      end
    end

    describe "format conversion utilities" do
      test "parse_fft_result converts flat list to complex tuples" do
        flat = [1.0, 0.0, 0.0, 1.0, 0.5, 0.5]
        result = SNIFBackend.parse_fft_result(flat, 3)
        
        assert result == [{1.0, 0.0}, {0.0, 1.0}, {0.5, 0.5}]
      end

      test "prepare_ifft_input converts complex tuples to flat list" do
        spectrum = [{1.0, 0.0}, {0.0, 1.0}]
        result = SNIFBackend.prepare_ifft_input(spectrum)
        
        assert result == [1.0, 0.0, 0.0, 1.0]
      end

      test "parse_ifft_result extracts real parts from complex result" do
        complex = [1.0, 0.0, 0.5, 0.0, 0.25, 0.0]
        result = SNIFBackend.parse_ifft_result(complex)
        
        assert result == [1.0, 0.5, 0.25]
      end
    end
end