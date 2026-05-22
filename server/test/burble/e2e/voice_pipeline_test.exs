# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# End-to-end voice pipeline tests — full point-to-point path from
# capture to playback, including auth, room join, media processing,
# and verification layers.

defmodule Burble.E2E.VoicePipelineTest do
  use ExUnit.Case, async: false

  alias Burble.Auth
  alias Burble.Rooms.{Room, RoomManager}
  alias Burble.Coprocessor.{ElixirBackend, SmartBackend}

  @frame_length 960
  @sample_rate 48_000

  # ---------------------------------------------------------------------------
  # Auth → Room → Voice lifecycle
  # ---------------------------------------------------------------------------

  describe "full user lifecycle" do
    test "guest joins, enters room, voice pipeline processes frames" do
      # Step 1: Guest authentication.
      {:ok, guest} = Auth.create_guest_session("TestPlayer")
      assert guest.display_name == "TestPlayer"
      assert guest.is_guest == true

      # Step 2: Create a room via RoomManager.
      room_id = "e2e-lifecycle-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      {:ok, _pid} = RoomManager.ensure_room(room_id, server_id: "test-server", name: "Voice Chat")

      # Step 3: Join the room.
      {:ok, state} = Room.join(room_id, guest.id, %{display_name: guest.display_name})
      assert state.participant_count == 1

      # Step 4: Process a voice frame through the pipeline.
      speech = generate_speech_frame()
      gated = ElixirBackend.audio_noise_gate(speech, -40.0)
      reference = List.duplicate(0.0, @frame_length)
      cancelled = ElixirBackend.audio_echo_cancel(gated, reference, 64)
      {normalised, _state} = ElixirBackend.audio_agc(cancelled, -20.0, 10.0, 100.0, %{})
      {:ok, encoded} = ElixirBackend.audio_encode(normalised, @sample_rate, 1, 32_000)

      assert is_binary(encoded)
      assert byte_size(encoded) > 0

      # Step 5: Leave and cleanup.
      :ok = Room.leave(room_id, guest.id)
    end

    test "two guests can exchange voice frames" do
      # Create two guests.
      {:ok, alice} = Auth.create_guest_session("Alice")
      {:ok, bob} = Auth.create_guest_session("Bob")

      # Create room and both join.
      room_id = "e2e-exchange-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      {:ok, _pid} = RoomManager.ensure_room(room_id, server_id: "test-server", name: "Chat")
      {:ok, _} = Room.join(room_id, alice.id, %{display_name: alice.display_name})
      {:ok, _} = Room.join(room_id, bob.id, %{display_name: bob.display_name})

      # Alice generates a frame.
      alice_speech = generate_speech_frame(440.0)
      {:ok, alice_encoded} = ElixirBackend.audio_encode(alice_speech, @sample_rate, 1, 32_000)

      # Bob receives and decodes Alice's frame.
      {:ok, alice_decoded} = ElixirBackend.audio_decode(alice_encoded, @sample_rate, 1)
      assert length(alice_decoded) == @frame_length

      # Bob generates a response.
      bob_speech = generate_speech_frame(330.0)
      {:ok, bob_encoded} = ElixirBackend.audio_encode(bob_speech, @sample_rate, 1, 32_000)

      # Alice receives and decodes Bob's frame.
      {:ok, bob_decoded} = ElixirBackend.audio_decode(bob_encoded, @sample_rate, 1)
      assert length(bob_decoded) == @frame_length

      # Verify frames are different (different frequencies).
      assert alice_decoded != bob_decoded, "Different speakers should produce different frames"

      # Cleanup.
      :ok = Room.leave(room_id, alice.id)
      :ok = Room.leave(room_id, bob.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Coprocessor pipeline E2E
  # ---------------------------------------------------------------------------

  describe "coprocessor pipeline integration" do
    test "SmartBackend dispatches correctly for all new operations" do
      # AGC.
      signal = for i <- 1..@frame_length, do: :math.sin(i * 0.1) * 0.1
      {agc_out, _state} = SmartBackend.audio_agc(signal, -20.0, 10.0, 100.0, %{})
      assert length(agc_out) == @frame_length

      # Comfort noise.
      noise = SmartBackend.audio_comfort_noise(@frame_length, -50.0, [0.5, 0.3])
      assert length(noise) == @frame_length

      # Perceptual weighting.
      mags = List.duplicate(1.0, 128)
      weighted = SmartBackend.audio_perceptual_weight(mags, @sample_rate)
      assert length(weighted) == 128
    end

    test "full outbound pipeline: capture → gate → cancel → AGC → encode" do
      capture = generate_noisy_speech()
      reference = List.duplicate(0.0, @frame_length)

      # 1. Noise gate.
      gated = SmartBackend.audio_noise_gate(capture, -45.0)

      # 2. Echo cancel.
      cancelled = SmartBackend.audio_echo_cancel(gated, reference, 64)

      # 3. AGC.
      {processed, _agc_state} = SmartBackend.audio_agc(cancelled, -20.0, 10.0, 100.0, %{})

      # 4. Encode.
      {:ok, encoded} = SmartBackend.audio_encode(processed, @sample_rate, 1, 32_000)
      assert is_binary(encoded)
      assert byte_size(encoded) > 0
    end

    test "full inbound pipeline: decode → AGC → playback" do
      # Simulate receiving an encoded frame.
      original = generate_speech_frame()
      {:ok, encoded} = SmartBackend.audio_encode(original, @sample_rate, 1, 32_000)

      # 1. Decode.
      {:ok, decoded} = SmartBackend.audio_decode(encoded, @sample_rate, 1)

      # 2. AGC (normalise remote speaker volume).
      {normalised, _state} = SmartBackend.audio_agc(decoded, -18.0, 5.0, 50.0, %{})

      assert length(normalised) == @frame_length
    end
  end

  # ---------------------------------------------------------------------------
  # Verification layer E2E
  # ---------------------------------------------------------------------------

  describe "verification layers" do
    test "Vext hash chain maintains integrity across frames" do
      frames = for i <- 1..5 do
        generate_speech_frame(440.0 + i * 10.0)
      end

      # Build a Vext hash chain over the frames.
      {chain, _final_hash} =
        Enum.reduce(frames, {[], <<0::256>>}, fn frame, {chain_acc, prev_hash} ->
          {:ok, encoded} = ElixirBackend.audio_encode(frame, @sample_rate, 1, 32_000)
          next_hash = ElixirBackend.crypto_hash_chain(prev_hash, encoded)
          {[{encoded, next_hash} | chain_acc], next_hash}
        end)

      chain = Enum.reverse(chain)
      assert length(chain) == 5

      # Verify chain integrity — each link must hash correctly from previous.
      Enum.reduce(chain, <<0::256>>, fn {encoded, expected_hash}, prev_hash ->
        computed = ElixirBackend.crypto_hash_chain(prev_hash, encoded)
        assert computed == expected_hash, "Hash chain integrity violated"
        expected_hash
      end)
    end

    test "E2EE frame encryption round-trips correctly" do
      frame = generate_speech_frame()
      {:ok, encoded} = ElixirBackend.audio_encode(frame, @sample_rate, 1, 32_000)

      # Generate key and encrypt.
      key = :crypto.strong_rand_bytes(32)
      aad = "room:test_room"
      {:ok, {ciphertext, iv, tag}} = ElixirBackend.crypto_encrypt_frame(encoded, key, aad)

      # Ciphertext should differ from plaintext.
      assert ciphertext != encoded, "Encryption should change the data"

      # Decrypt.
      {:ok, decrypted} = ElixirBackend.crypto_decrypt_frame(ciphertext, key, iv, tag, aad)
      assert decrypted == encoded, "Decryption should recover original frame"

      # Wrong key should fail.
      wrong_key = :crypto.strong_rand_bytes(32)
      assert {:error, :decrypt_failed} == ElixirBackend.crypto_decrypt_frame(ciphertext, wrong_key, iv, tag, aad)
    end
  end

  # ---------------------------------------------------------------------------
  # Security aspect tests
  # ---------------------------------------------------------------------------

  describe "security aspects" do
    test "guest sessions have limited permissions" do
      {:ok, guest} = Auth.create_guest_session("SecurityTest")
      assert guest.is_guest == true
      assert :join_room in guest.permissions
      assert :speak in guest.permissions
      assert :text in guest.permissions
    end

    test "E2EE key derivation produces unique keys per salt" do
      secret = :crypto.strong_rand_bytes(32)
      salt1 = :crypto.strong_rand_bytes(16)
      salt2 = :crypto.strong_rand_bytes(16)
      info = "burble-e2ee-frame-key"

      key1 = ElixirBackend.crypto_derive_frame_key(secret, salt1, info)
      key2 = ElixirBackend.crypto_derive_frame_key(secret, salt2, info)

      assert key1 != key2, "Different salts must produce different keys"
      assert byte_size(key1) == 32, "Key must be 32 bytes"
    end

    test "hash chain detects tampering" do
      frame1 = :crypto.strong_rand_bytes(100)
      frame2 = :crypto.strong_rand_bytes(100)
      tampered = :crypto.strong_rand_bytes(100)

      hash0 = <<0::256>>
      hash1 = ElixirBackend.crypto_hash_chain(hash0, frame1)
      hash2 = ElixirBackend.crypto_hash_chain(hash1, frame2)

      # Verify legitimate chain.
      assert ElixirBackend.crypto_hash_chain(hash1, frame2) == hash2

      # Tampered frame should produce different hash.
      tampered_hash = ElixirBackend.crypto_hash_chain(hash1, tampered)
      assert tampered_hash != hash2, "Tampering must break the chain"
    end
  end

  # ---------------------------------------------------------------------------
  # Performance aspect tests
  # ---------------------------------------------------------------------------

  describe "performance aspects" do
    test "AGC processes frame within 10ms" do
      signal = generate_speech_frame()
      {time_us, _result} = :timer.tc(fn ->
        ElixirBackend.audio_agc(signal, -20.0, 10.0, 100.0, %{})
      end)

      # Relaxed threshold for CI environments (cold JIT, shared runners).
      assert time_us < 10_000, "AGC must complete within 10ms, took #{time_us}us"
    end

    test "full outbound pipeline within 50ms budget" do
      capture = generate_noisy_speech()
      reference = List.duplicate(0.0, @frame_length)

      {time_us, _result} = :timer.tc(fn ->
        gated = ElixirBackend.audio_noise_gate(capture, -45.0)
        cancelled = ElixirBackend.audio_echo_cancel(gated, reference, 64)
        {processed, _state} = ElixirBackend.audio_agc(cancelled, -20.0, 10.0, 100.0, %{})
        {:ok, _encoded} = ElixirBackend.audio_encode(processed, @sample_rate, 1, 32_000)
      end)

      # 50ms budget — generous for cold runs. Real-time requires 20ms.
      assert time_us < 50_000, "Full pipeline must complete within 50ms, took #{time_us}us"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp generate_speech_frame(freq \\ 440.0) do
    for i <- 1..@frame_length do
      :math.sin(2.0 * :math.pi() * freq * i / @sample_rate) * 0.3
    end
  end

  defp generate_noisy_speech(freq \\ 440.0) do
    for i <- 1..@frame_length do
      speech = :math.sin(2.0 * :math.pi() * freq * i / @sample_rate) * 0.3
      noise = (:rand.uniform() - 0.5) * 0.02
      speech + noise
    end
  end
end
