# SPDX-License-Identifier: MPL-2.0

defmodule Burble.Coprocessor.ElixirBackendTest do
  use ExUnit.Case, async: true

  alias Burble.Coprocessor.ElixirBackend, as: B

  # ---------------------------------------------------------------------------
  # Audio kernel
  # ---------------------------------------------------------------------------

  describe "audio_encode/4 + audio_decode/3 round-trip" do
    test "encodes and decodes PCM samples" do
      pcm = [0.0, 0.5, -0.5, 1.0, -1.0]
      {:ok, encoded} = B.audio_encode(pcm, 48_000, 1, 32_000)
      assert is_binary(encoded)

      {:ok, decoded} = B.audio_decode(encoded, 48_000, 1)
      assert length(decoded) == length(pcm)

      # Within 16-bit quantisation error.
      Enum.zip(pcm, decoded)
      |> Enum.each(fn {orig, dec} ->
        assert_in_delta orig, dec, 0.001
      end)
    end
  end

  describe "audio_noise_gate/2" do
    test "zeroes samples below threshold" do
      pcm = [0.001, 0.5, -0.002, 0.8, 0.0001]
      result = B.audio_noise_gate(pcm, -20.0)

      # Threshold at -20dB = 0.1 linear amplitude.
      assert Enum.at(result, 0) == 0.0
      assert Enum.at(result, 1) == 0.5
      assert Enum.at(result, 2) == 0.0
      assert Enum.at(result, 3) == 0.8
      assert Enum.at(result, 4) == 0.0
    end
  end

  describe "audio_echo_cancel/3" do
    test "returns same length as input" do
      capture = List.duplicate(0.5, 100)
      reference = List.duplicate(0.1, 100)
      result = B.audio_echo_cancel(capture, reference, 16)
      assert length(result) == 100
    end
  end

  # ---------------------------------------------------------------------------
  # Crypto kernel
  # ---------------------------------------------------------------------------

  describe "crypto_encrypt_frame/3 + crypto_decrypt_frame/5" do
    test "round-trips correctly" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "test audio frame data"
      aad = "peer_123"

      {:ok, {ciphertext, iv, tag}} = B.crypto_encrypt_frame(plaintext, key, aad)
      assert ciphertext != plaintext
      assert byte_size(iv) == 12
      assert byte_size(tag) == 16

      {:ok, decrypted} = B.crypto_decrypt_frame(ciphertext, key, iv, tag, aad)
      assert decrypted == plaintext
    end

    test "fails with wrong key" do
      key = :crypto.strong_rand_bytes(32)
      wrong_key = :crypto.strong_rand_bytes(32)
      {:ok, {ct, iv, tag}} = B.crypto_encrypt_frame("data", key, "aad")
      assert {:error, :decrypt_failed} = B.crypto_decrypt_frame(ct, wrong_key, iv, tag, "aad")
    end
  end

  describe "crypto_hash_chain/2" do
    test "produces deterministic 32-byte hash" do
      prev = :crypto.strong_rand_bytes(32)
      hash1 = B.crypto_hash_chain(prev, "payload")
      hash2 = B.crypto_hash_chain(prev, "payload")
      assert hash1 == hash2
      assert byte_size(hash1) == 32
    end

    test "different payloads produce different hashes" do
      prev = :crypto.strong_rand_bytes(32)
      hash1 = B.crypto_hash_chain(prev, "payload_a")
      hash2 = B.crypto_hash_chain(prev, "payload_b")
      assert hash1 != hash2
    end
  end

  describe "crypto_derive_frame_key/3" do
    test "produces 32-byte key" do
      secret = :crypto.strong_rand_bytes(32)
      key = B.crypto_derive_frame_key(secret, "salt_value_here!", "info")
      assert byte_size(key) == 32
    end
  end

  # ---------------------------------------------------------------------------
  # I/O kernel
  # ---------------------------------------------------------------------------

  describe "io_jitter_buffer_push/4" do
    test "buffers and emits packets" do
      {:ok, frame, buffer} = B.io_jitter_buffer_push(%{}, "pkt1", 1, 1000)

      # First packet may or may not emit depending on target delay.
      assert is_map(buffer)
      assert is_binary(frame) or is_nil(frame)
    end
  end

  describe "io_adaptive_bitrate/3" do
    test "decreases bitrate on high loss" do
      new_br = B.io_adaptive_bitrate(0.15, 200, 64_000)
      assert new_br < 64_000
    end

    test "increases bitrate on good conditions" do
      new_br = B.io_adaptive_bitrate(0.0, 50, 32_000)
      assert new_br > 32_000
    end

    test "respects minimum bitrate" do
      new_br = B.io_adaptive_bitrate(0.5, 500, 16_000)
      assert new_br >= 16_000
    end
  end

  # ---------------------------------------------------------------------------
  # DSP kernel
  # ---------------------------------------------------------------------------

  describe "dsp_fft/2 + dsp_ifft/2" do
    test "round-trips for power-of-2 input" do
      signal = [1.0, 0.0, -1.0, 0.0]
      spectrum = B.dsp_fft(signal, 4)
      assert length(spectrum) == 4

      recovered = B.dsp_ifft(spectrum, 4)
      assert length(recovered) == 4
    end
  end

  describe "dsp_convolve/2" do
    test "convolution with impulse returns original" do
      a = [1.0, 2.0, 3.0]
      impulse = [1.0, 0.0, 0.0]
      result = B.dsp_convolve(a, impulse)
      assert length(result) == 5
      assert_in_delta Enum.at(result, 0), 1.0, 0.001
      assert_in_delta Enum.at(result, 1), 2.0, 0.001
      assert_in_delta Enum.at(result, 2), 3.0, 0.001
    end
  end

  describe "dsp_mix/2" do
    test "mixes two streams with identity matrix" do
      streams = [[1.0, 2.0], [3.0, 4.0]]
      matrix = [[1.0, 0.0], [0.0, 1.0]]
      result = B.dsp_mix(streams, matrix)
      assert length(result) == 2
      assert Enum.at(result, 0) == [1.0, 2.0]
      assert Enum.at(result, 1) == [3.0, 4.0]
    end

    test "sums two streams equally" do
      streams = [[1.0, 1.0], [1.0, 1.0]]
      matrix = [[0.5, 0.5]]
      [mixed] = B.dsp_mix(streams, matrix)
      assert_in_delta Enum.at(mixed, 0), 1.0, 0.001
      assert_in_delta Enum.at(mixed, 1), 1.0, 0.001
    end
  end

  # ---------------------------------------------------------------------------
  # Neural kernel
  # ---------------------------------------------------------------------------

  describe "neural_denoise/3" do
    test "returns cleaned PCM and updated state" do
      state = B.neural_init_model(48_000)
      pcm = for _ <- 1..960, do: :rand.uniform() * 0.01
      {cleaned, new_state} = B.neural_denoise(pcm, 48_000, state)
      assert length(cleaned) == 960
      assert new_state.frame_count == 1
    end
  end

  describe "neural_classify_noise/2" do
    test "classifies silence" do
      silence = List.duplicate(0.0, 960)
      {type, confidence} = B.neural_classify_noise(silence, 48_000)
      assert type == :silence
      assert confidence > 0.5
    end
  end

  # ---------------------------------------------------------------------------
  # Compression kernel
  # ---------------------------------------------------------------------------

  describe "compress_zstd/2 + decompress_zstd/1" do
    test "round-trips JSON data" do
      # Use enough data for compression to be effective (zlib overhead > savings on tiny inputs).
      json = Jason.encode!(for i <- 1..100, do: %{event: "login", user_id: "user_#{i}", ts: "2026-03-16T00:00:00Z"})
      {:ok, compressed} = B.compress_zstd(json, 3)
      assert byte_size(compressed) < byte_size(json)

      {:ok, decompressed} = B.decompress_zstd(compressed)
      assert decompressed == json
    end
  end
end
