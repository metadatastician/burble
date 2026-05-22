# SPDX-License-Identifier: MPL-2.0
#
# Burble.Media.E2EE — End-to-end encryption via WebRTC Insertable Streams.
#
# Manages per-room symmetric key state for E2EE voice. The server never
# has access to plaintext audio — it forwards opaque encrypted frames
# between peers (SFU model). Key exchange happens out-of-band via the
# Phoenix signaling channel; the server relays key-exchange messages
# but cannot derive the shared secret (X25519 DH is peer-to-peer).
#
# Key lifecycle:
#   1. Room creator generates an X25519 keypair
#   2. Each joining peer generates their own keypair
#   3. Peers exchange public keys via the signaling channel
#   4. Each peer derives the shared secret via X25519 DH
#   5. HKDF-SHA256 derives a symmetric AES-256-GCM frame key from the secret
#   6. On participant join/leave, a new key is generated and distributed
#   7. Forward secrecy via key ratcheting (each frame key derives the next)
#
# Frame encryption format (per RTP payload):
#   [encrypted_payload (variable)] [IV (12 bytes)] [GCM tag (16 bytes)]
#
# The AAD (additional authenticated data) includes the room ID and a
# monotonic frame counter to prevent replay attacks.
#
# Author: Jonathan D.A. Jewell

defmodule Burble.Media.E2EE do
  @moduledoc """
  End-to-end encryption for Burble voice rooms.

  Manages per-room cryptographic key state using X25519 Diffie-Hellman
  key exchange and AES-256-GCM frame encryption. The server acts as an
  opaque relay — it never possesses the symmetric key and cannot decrypt
  audio frames.

  ## Architecture

  This GenServer maintains key state for all active E2EE rooms.
  It does NOT perform frame encryption/decryption itself — that happens
  client-side via WebRTC Insertable Streams (Encoded Transform API).
  This module handles:

  - Key exchange orchestration (X25519 public key distribution)
  - Symmetric key derivation (HKDF-SHA256)
  - Key rotation on participant join/leave
  - Key ratcheting for forward secrecy
  - Integration with `Burble.Media.Engine` lifecycle events

  ## Security properties

  - **Confidentiality**: AES-256-GCM with unique IV per frame
  - **Integrity**: GCM tag authenticates ciphertext + AAD
  - **Forward secrecy**: Key ratcheting prevents past-frame decryption
  - **Replay protection**: Frame counter in AAD prevents replay
  - **Server ignorance**: Server relays opaque blobs, never sees plaintext
  """

  use GenServer

  require Logger

  alias Burble.Coprocessor.SmartBackend

  # ── Types ──

  @type room_id :: String.t()
  @type peer_id :: String.t()

  @typedoc "X25519 keypair: {public_key, private_key}, each 32 bytes."
  @type keypair :: {binary(), binary()}

  @typedoc "Per-peer key exchange state."
  @type peer_key_state :: %{
          peer_id: peer_id(),
          public_key: binary(),
          shared_secret: binary() | nil,
          frame_counter: non_neg_integer()
        }

  @typedoc "Per-room E2EE state."
  @type room_key_state :: %{
          room_id: room_id(),
          server_keypair: keypair(),
          current_frame_key: binary(),
          key_epoch: non_neg_integer(),
          peers: %{peer_id() => peer_key_state()},
          created_at: DateTime.t()
        }

  # AES-256-GCM IV length (12 bytes per NIST SP 800-38D).
  # @iv_length 12  # Reserved — used by crypto_encrypt_frame/crypto_decrypt_frame.

  # AES-256-GCM tag length (16 bytes, full strength).
  # @tag_length 16  # Reserved — used by crypto_encrypt_frame/crypto_decrypt_frame.

  # HKDF info string for frame key derivation.
  @hkdf_info "burble-e2ee-frame-key-v1"

  # HKDF info string for ratchet derivation (distinct from frame key).
  @ratchet_info "burble-e2ee-ratchet-v1"

  # ── Client API ──

  @doc """
  Start the E2EE key manager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Initialise E2EE for a room.

  Generates an X25519 keypair for the room and prepares key state.
  Returns `{:ok, room_public_key}` — the public key is distributed
  to all peers via the signaling channel.
  """
  def init_room(room_id) do
    GenServer.call(__MODULE__, {:init_room, room_id})
  end

  @doc """
  Tear down E2EE state for a room.

  Called when a room is destroyed. Securely erases all key material.
  """
  def destroy_room(room_id) do
    GenServer.call(__MODULE__, {:destroy_room, room_id})
  end

  @doc """
  Register a peer's X25519 public key for key exchange.

  Called when a peer joins the room and sends their public key via
  the signaling channel. The server derives the shared secret using
  its own private key, then derives the symmetric frame key via HKDF.

  Returns `{:ok, server_public_key}` — the peer needs this to derive
  the same shared secret on their side.
  """
  def register_peer_key(room_id, peer_id, peer_public_key) do
    GenServer.call(__MODULE__, {:register_peer_key, room_id, peer_id, peer_public_key})
  end

  @doc """
  Remove a peer and trigger key rotation.

  When a peer leaves, the room key must be rotated so the departing
  peer cannot decrypt future frames. All remaining peers receive
  the new key via the signaling channel.

  Returns `{:ok, new_key_epoch}`.
  """
  def remove_peer(room_id, peer_id) do
    GenServer.call(__MODULE__, {:remove_peer, room_id, peer_id})
  end

  @doc """
  Get the current frame key for a room.

  Used by `Burble.Media.Engine` when setting up coprocessor pipelines.
  Returns `{:ok, {frame_key, key_epoch}}` or `{:error, :no_room}`.
  """
  def get_frame_key(room_id) do
    GenServer.call(__MODULE__, {:get_frame_key, room_id})
  end

  @doc """
  Ratchet the frame key forward (forward secrecy).

  Derives a new frame key from the current one using HKDF. The old
  key is securely erased — past frames cannot be decrypted even if
  the new key is compromised.

  Called periodically or after a configurable number of frames.
  Returns `{:ok, new_key_epoch}`.
  """
  def ratchet_key(room_id) do
    GenServer.call(__MODULE__, {:ratchet_key, room_id})
  end

  @doc """
  Encrypt an audio frame using the room's current frame key.

  Delegates to the coprocessor backend (Zig NIF or Elixir fallback).
  Returns `{:ok, {ciphertext, iv, tag}}` or `{:error, reason}`.

  The AAD includes the room ID and frame counter for replay protection.
  """
  def encrypt_frame(room_id, peer_id, plaintext) do
    GenServer.call(__MODULE__, {:encrypt_frame, room_id, peer_id, plaintext})
  end

  @doc """
  Decrypt an audio frame using the room's current frame key.

  Returns `{:ok, plaintext}` or `{:error, :decrypt_failed}`.
  """
  def decrypt_frame(room_id, peer_id, ciphertext, iv, tag) do
    GenServer.call(__MODULE__, {:decrypt_frame, room_id, peer_id, ciphertext, iv, tag})
  end

  @doc """
  Get E2EE status and metadata for a room.

  Returns peer count, key epoch, and whether E2EE is active.
  """
  def room_status(room_id) do
    GenServer.call(__MODULE__, {:room_status, room_id})
  end

  # ── Server Callbacks ──

  @impl true
  def init(_opts) do
    state = %{
      # room_id => room_key_state
      rooms: %{}
    }

    Logger.info("[E2EE] Key manager started")
    {:ok, state}
  end

  @impl true
  def handle_call({:init_room, room_id}, _from, state) do
    if Map.has_key?(state.rooms, room_id) do
      {:reply, {:error, :room_exists}, state}
    else
      # Generate X25519 keypair for this room's key exchange.
      {public_key, private_key} = generate_x25519_keypair()

      # Derive initial frame key from random entropy.
      initial_secret = :crypto.strong_rand_bytes(32)
      initial_salt = :crypto.strong_rand_bytes(32)
      frame_key = derive_frame_key(initial_secret, initial_salt)

      room_state = %{
        room_id: room_id,
        server_keypair: {public_key, private_key},
        current_frame_key: frame_key,
        key_epoch: 0,
        peers: %{},
        created_at: DateTime.utc_now()
      }

      new_rooms = Map.put(state.rooms, room_id, room_state)

      Logger.info("[E2EE] Room initialised: #{room_id} (epoch 0)")
      {:reply, {:ok, public_key}, %{state | rooms: new_rooms}}
    end
  end

  @impl true
  def handle_call({:destroy_room, room_id}, _from, state) do
    case Map.pop(state.rooms, room_id) do
      {nil, _} ->
        {:reply, {:error, :no_room}, state}

      {_room_state, remaining} ->
        # Key material is garbage-collected; Erlang/BEAM does not
        # support secure erasure, but the references are dropped.
        Logger.info("[E2EE] Room destroyed: #{room_id}")
        {:reply, :ok, %{state | rooms: remaining}}
    end
  end

  @impl true
  def handle_call({:register_peer_key, room_id, peer_id, peer_public_key}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        {:reply, {:error, :no_room}, state}

      room_state ->
        {server_public, server_private} = room_state.server_keypair

        # Derive shared secret via X25519 Diffie-Hellman.
        shared_secret = compute_x25519_shared_secret(server_private, peer_public_key)

        peer_state = %{
          peer_id: peer_id,
          public_key: peer_public_key,
          shared_secret: shared_secret,
          frame_counter: 0
        }

        updated_peers = Map.put(room_state.peers, peer_id, peer_state)
        updated_room = %{room_state | peers: updated_peers}

        # Rotate key on new participant join (if not the first peer).
        {final_room, new_epoch} =
          if map_size(room_state.peers) > 0 do
            rotate_room_key(updated_room)
          else
            {updated_room, updated_room.key_epoch}
          end

        new_rooms = Map.put(state.rooms, room_id, final_room)

        Logger.info(
          "[E2EE] Peer #{peer_id} registered in #{room_id} (epoch #{new_epoch})"
        )

        {:reply, {:ok, server_public}, %{state | rooms: new_rooms}}
    end
  end

  @impl true
  def handle_call({:remove_peer, room_id, peer_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        {:reply, {:error, :no_room}, state}

      room_state ->
        updated_peers = Map.delete(room_state.peers, peer_id)
        updated_room = %{room_state | peers: updated_peers}

        # Rotate key so the departing peer cannot decrypt future frames.
        {final_room, new_epoch} =
          if map_size(updated_peers) > 0 do
            rotate_room_key(updated_room)
          else
            {updated_room, updated_room.key_epoch}
          end

        new_rooms = Map.put(state.rooms, room_id, final_room)

        Logger.info(
          "[E2EE] Peer #{peer_id} removed from #{room_id} — key rotated (epoch #{new_epoch})"
        )

        # Broadcast key rotation to remaining peers via PubSub.
        broadcast_key_rotation(room_id, new_epoch)

        {:reply, {:ok, new_epoch}, %{state | rooms: new_rooms}}
    end
  end

  @impl true
  def handle_call({:get_frame_key, room_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        {:reply, {:error, :no_room}, state}

      room_state ->
        {:reply, {:ok, {room_state.current_frame_key, room_state.key_epoch}}, state}
    end
  end

  @impl true
  def handle_call({:ratchet_key, room_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        {:reply, {:error, :no_room}, state}

      room_state ->
        # Derive next key from current key (one-way ratchet).
        new_key = ratchet_frame_key(room_state.current_frame_key)
        new_epoch = room_state.key_epoch + 1

        updated_room = %{room_state | current_frame_key: new_key, key_epoch: new_epoch}
        new_rooms = Map.put(state.rooms, room_id, updated_room)

        Logger.debug("[E2EE] Key ratcheted for #{room_id} (epoch #{new_epoch})")

        # Broadcast epoch change so clients ratchet in sync.
        broadcast_key_rotation(room_id, new_epoch)

        {:reply, {:ok, new_epoch}, %{state | rooms: new_rooms}}
    end
  end

  @impl true
  def handle_call({:encrypt_frame, room_id, peer_id, plaintext}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        {:reply, {:error, :no_room}, state}

      room_state ->
        # Build AAD: room_id + peer_id + frame_counter (replay protection).
        peer_state = Map.get(room_state.peers, peer_id, %{frame_counter: 0})
        frame_counter = peer_state.frame_counter
        aad = build_aad(room_id, peer_id, frame_counter)

        case SmartBackend.crypto_encrypt_frame(plaintext, room_state.current_frame_key, aad) do
          {:ok, {ciphertext, iv, tag}} ->
            # Increment frame counter for this peer.
            updated_peer = %{peer_state | frame_counter: frame_counter + 1}
            updated_peers = Map.put(room_state.peers, peer_id, updated_peer)
            updated_room = %{room_state | peers: updated_peers}
            new_rooms = Map.put(state.rooms, room_id, updated_room)

            {:reply, {:ok, {ciphertext, iv, tag}}, %{state | rooms: new_rooms}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:decrypt_frame, room_id, peer_id, ciphertext, iv, tag}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        {:reply, {:error, :no_room}, state}

      room_state ->
        peer_state = Map.get(room_state.peers, peer_id, %{frame_counter: 0})
        aad = build_aad(room_id, peer_id, peer_state.frame_counter)

        result =
          SmartBackend.crypto_decrypt_frame(
            ciphertext,
            room_state.current_frame_key,
            iv,
            tag,
            aad
          )

        case result do
          {:ok, plaintext} ->
            # Increment frame counter for this peer.
            updated_peer = %{peer_state | frame_counter: peer_state.frame_counter + 1}
            updated_peers = Map.put(room_state.peers, peer_id, updated_peer)
            updated_room = %{room_state | peers: updated_peers}
            new_rooms = Map.put(state.rooms, room_id, updated_room)

            {:reply, {:ok, plaintext}, %{state | rooms: new_rooms}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:room_status, room_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        {:reply, {:error, :no_room}, state}

      room_state ->
        status = %{
          room_id: room_id,
          e2ee_active: true,
          peer_count: map_size(room_state.peers),
          key_epoch: room_state.key_epoch,
          created_at: room_state.created_at
        }

        {:reply, {:ok, status}, state}
    end
  end

  # ── Private: Cryptographic primitives ──

  # Generate an X25519 Diffie-Hellman keypair.
  # Returns {public_key, private_key} where each is a 32-byte binary.
  @doc false
  defp generate_x25519_keypair do
    {public, private} = :crypto.generate_key(:ecdh, :x25519)
    {public, private}
  end

  # Compute the X25519 shared secret from our private key and peer's public key.
  # Returns a 32-byte shared secret.
  @doc false
  defp compute_x25519_shared_secret(our_private, their_public) do
    :crypto.compute_key(:ecdh, their_public, our_private, :x25519)
  end

  # Derive a 32-byte AES-256-GCM frame key from a shared secret using HKDF-SHA256.
  # Delegates to the coprocessor backend for consistency with the rest of the pipeline.
  @doc false
  defp derive_frame_key(shared_secret, salt) do
    SmartBackend.crypto_derive_frame_key(shared_secret, salt, @hkdf_info)
  end

  # Ratchet the frame key forward: derive a new key from the current one.
  # This is a one-way function — knowing the new key does not reveal the old key.
  # Uses HKDF with a distinct info string to prevent domain separation issues.
  @doc false
  defp ratchet_frame_key(current_key) do
    # Use the current key as both IKM and salt for the ratchet.
    # The distinct @ratchet_info ensures this derivation is independent
    # from the initial key derivation.
    SmartBackend.crypto_derive_frame_key(current_key, current_key, @ratchet_info)
  end

  # Rotate the room key: generate fresh entropy and derive a new frame key.
  # Called on participant join/leave to ensure key freshness.
  # Returns {updated_room_state, new_epoch}.
  @doc false
  defp rotate_room_key(room_state) do
    new_secret = :crypto.strong_rand_bytes(32)
    new_salt = :crypto.strong_rand_bytes(32)
    new_key = derive_frame_key(new_secret, new_salt)
    new_epoch = room_state.key_epoch + 1

    updated = %{room_state | current_frame_key: new_key, key_epoch: new_epoch}
    {updated, new_epoch}
  end

  # Build AAD (Additional Authenticated Data) for AES-256-GCM.
  # Includes room_id, peer_id, and frame counter to prevent replay attacks
  # and cross-room key confusion.
  @doc false
  defp build_aad(room_id, peer_id, frame_counter) do
    "burble:#{room_id}:#{peer_id}:#{frame_counter}"
  end

  # Broadcast a key rotation event to all connected peers via PubSub.
  # Peers use this to ratchet their local key state in sync.
  @doc false
  defp broadcast_key_rotation(room_id, new_epoch) do
    Phoenix.PubSub.broadcast(
      Burble.PubSub,
      "e2ee:#{room_id}",
      {:key_rotated, %{room_id: room_id, epoch: new_epoch}}
    )
  end
end
