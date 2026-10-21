# SPDX-License-Identifier: MPL-2.0
#
# Burble.Media.E2EE — peer-held group keys for voice rooms.
#
# The design rule this module now enforces (ADR-0016, 2026-10-21):
#
#   The server stores public keys and opaque blobs. It never generates,
#   receives, derives, logs or returns a symmetric room key.
#
# What that means in practice:
#
#   * Every peer generates its own ephemeral X25519 keypair, client-side.
#   * Peers publish only their PUBLIC key; the server relays it to the room.
#   * Any two peers can derive a pairwise key from (my private, their public) —
#     and so can nobody else, including this process.
#   * One peer per epoch (the "key leader" — lowest peer id, deterministic)
#     generates a random 32-byte room key and sends it to every other peer
#     SEALED under that pairwise key. The server sees ciphertext it cannot open.
#   * Membership change ⇒ new epoch ⇒ new room key ⇒ re-seal. A departing peer
#     never learns the next key; a joining peer never learns past ones.
#   * Frame keys are derived from the room key on the peers, per frame counter.
#
# This module is therefore a *coordination* service plus a set of pure
# functions that both ends of the protocol (browser client, tests, any future
# native client) can mirror. The functions are marked "PEER-SIDE": they only
# make sense on a machine that holds a private key. Nothing here calls them
# with key material the server owns, because it owns none.
#
# ## Status: part-way
#
# Implemented and tested here:
#   - peer key registration, epoch handling, revocation on membership change
#   - pairwise key agreement, group-key sealing/opening, frame-key derivation
#   - opaque, size-bounded distribution storage with per-peer retrieval
#
# NOT yet implemented (tracked in the maintenance report):
#   - the browser side: WebCrypto X25519 + AES-GCM + Insertable Streams
#     (Encoded Transform) wiring in client/web. Until that lands, rooms are
#     encrypted in transit by DTLS-SRTP only and MUST NOT be called E2EE.
#   - multi-leader failover if the leader disconnects mid-epoch (today the
#     remaining peers re-elect on the next epoch bump).
#
# Everything above is stated the same way in README.adoc so the code and the
# front page cannot drift apart again.

defmodule Burble.Media.E2EE do
  @moduledoc """
  Peer-held group-key coordination for Burble voice rooms.

  ## Division of responsibility

  | Concern | Where it happens |
  |---|---|
  | X25519 keypair generation | peer (client) |
  | Pairwise key agreement | peer, via `pairwise_key/6` |
  | Room key generation | peer, via `random_group_key/0` |
  | Room key distribution | peer → peer, sealed; server relays opaque blobs |
  | Frame encryption | peer (Insertable Streams) |
  | Membership, epochs, revocation | this module |

  The server's view of a room is `%{epoch, peers: %{peer_id => public_key},
  sealed: %{peer_id => opaque_blob}}`. There is deliberately no API that
  returns a key: `key_set/1` returns public keys only, and `room_status/1`
  reports `key_custody: :peers`.

  ## Protocol sketch

      # every peer, locally
      {my_pub, my_priv} = E2EE.generate_keypair()
      publish my_pub                      # -> signalling channel -> register_peer_key/3

      # leader (lowest peer id), once it has everyone's public key
      {:ok, pairwise} = E2EE.pairwise_key(my_priv, their_pub, room, epoch, me, them)
      room_key = E2EE.random_group_key()
      {:ok, sealed} = E2EE.seal_group_key(room_key, pairwise, room, epoch, me, them)
      publish sealed for `them`           # -> publish_sealed/4

      # each other peer
      {:ok, %{blob: sealed}} = fetch my blob   # -> sealed_for/2
      {:ok, pairwise} = E2EE.pairwise_key(my_priv, leader_pub, room, epoch, me, leader)
      {:ok, room_key} = E2EE.open_group_key(sealed, pairwise, room, epoch, leader, me)

  ## Threat model

  In scope: a curious or compromised *server*, passive network observers, and a
  peer that has left the room. Out of scope: a compromised *peer* (it holds the
  key by construction — this is a shared-key group protocol, not per-sender
  ratcheting), endpoint compromise, and denial of service.
  """

  use GenServer

  require Logger

  # ── Types ──

  @typedoc "X25519 keypair: {public_key, private_key}, each 32 bytes."
  @type keypair :: {binary(), binary()}

  @typedoc "Peer-side key material — never constructed by the server."
  @type group_key :: <<_::256>>

  @typedoc "Sealed room key as it travels through the server."
  @type sealed_key :: {ciphertext :: binary(), iv :: binary(), tag :: binary()}

  @typedoc "Public view of a room."
  @type key_set :: %{
          room_id: String.t(),
          epoch: non_neg_integer(),
          peers: %{(peer_id :: String.t()) => public_key :: binary()}
        }

  @typedoc "Server-side room state — public keys and opaque blobs only."
  @type room_state :: %{
          room_id: String.t(),
          epoch: non_neg_integer(),
          peers: %{String.t() => %{public_key: binary(), joined_at: DateTime.t()}},
          sealed: %{String.t() => %{epoch: non_neg_integer(), blob: binary()}},
          created_at: DateTime.t(),
          rotated_at: DateTime.t() | nil
        }

  # ── Constants ──

  # X25519 keys and HKDF outputs are 32 bytes; AES-256-GCM IVs are 12.
  @key_bytes 32
  @iv_bytes 12
  @tag_bytes 16

  # Domain-separation labels. Changing any of these is a wire break.
  @label_pairwise "burble-e2ee-pairwise-v1"
  @label_group "burble-e2ee-group-v1"
  @label_frame "burble-e2ee-frame-v1"

  # A sealed room key is 32 bytes of ciphertext + 12 IV + 16 tag = 60 bytes.
  # 512 is generous and stops the unauthenticated-ish distribution path from
  # being used as free storage.
  @max_sealed_bytes 512

  # Bound the peer map so a room cannot grow without limit.
  @max_peers 512

  @lifecycle_topic "e2ee:lifecycle"

  # ── Peer-facing API ──

  @doc """
  Start the key coordinator.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a room. No key material is created — epoch 0 starts empty and waits
  for peers to publish their public keys.
  """
  @spec init_room(String.t()) :: {:ok, %{epoch: non_neg_integer()}} | {:error, term()}
  def init_room(room_id) when is_binary(room_id) do
    GenServer.call(__MODULE__, {:init_room, room_id})
  end

  @doc "Tear down a room's coordination state (no key material to erase)."
  @spec destroy_room(String.t()) :: :ok | {:error, term()}
  def destroy_room(room_id) do
    GenServer.call(__MODULE__, {:destroy_room, room_id})
  end

  @doc """
  Record a peer's X25519 public key.

  If the room's key has already been distributed (any sealed blob exists) and
  the peer set changed, the epoch is bumped and every sealed blob is dropped —
  the new member cannot read the old key and the old key is no longer current.
  """
  @spec register_peer_key(String.t(), String.t(), binary()) ::
          {:ok, %{epoch: non_neg_integer(), peer_count: non_neg_integer()}} | {:error, term()}
  def register_peer_key(room_id, peer_id, public_key) do
    GenServer.call(__MODULE__, {:register_peer_key, room_id, peer_id, public_key})
  end

  @doc """
  Drop a peer and rotate.

  Rotation here means "invalidate": the epoch advances and the sealed blobs are
  discarded, so the room key that the departing peer holds can never be the
  current one. Peers re-derive with fresh ephemeral keys on the new epoch.
  """
  @spec remove_peer(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def remove_peer(room_id, peer_id) do
    GenServer.call(__MODULE__, {:remove_peer, room_id, peer_id})
  end

  @doc """
  Force a rotation (used by the periodic `Burble.Security.KeyRotation` sweep).
  """
  @spec request_rotation(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def request_rotation(room_id) do
    GenServer.call(__MODULE__, {:request_rotation, room_id})
  end

  @doc """
  Public key set for a room: everything a peer needs to derive pairwise keys.

  Contains no secret material by construction.
  """
  @spec key_set(String.t()) :: {:ok, key_set()} | {:error, term()}
  def key_set(room_id) do
    GenServer.call(__MODULE__, {:key_set, room_id})
  end

  @doc """
  Store an opaque sealed room key destined for one peer.

  The leader computes this peer-side; the server only checks size and epoch.
  """
  @spec publish_sealed(String.t(), String.t(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def publish_sealed(room_id, peer_id, epoch, blob) do
    GenServer.call(__MODULE__, {:publish_sealed, room_id, peer_id, epoch, blob})
  end

  @doc """
  Fetch the sealed room key addressed to `peer_id` for the current epoch.
  """
  @spec sealed_for(String.t(), String.t()) ::
          {:ok, %{epoch: non_neg_integer(), blob: binary()}} | {:error, term()}
  def sealed_for(room_id, peer_id) do
    GenServer.call(__MODULE__, {:sealed_for, room_id, peer_id})
  end

  @doc """
  Room status. Reports `key_custody: :peers` — the server holds no key.
  """
  @spec room_status(String.t()) :: {:ok, map()} | {:error, :no_room}
  def room_status(room_id) do
    GenServer.call(__MODULE__, {:room_status, room_id})
  end

  # ── PEER-SIDE pure functions ──
  #
  # These are the protocol. They are pure, deterministic and independent of
  # this process's state, so a browser (WebCrypto), a native client and the
  # test suite can all implement the same bytes.

  @doc """
  Generate an ephemeral X25519 keypair. **Peer-side.**

  Returns `{public_key, private_key}`.
  """
  @spec generate_keypair() :: keypair()
  def generate_keypair, do: :crypto.generate_key(:ecdh, :x25519)

  @doc """
  Generate a random 32-byte room key. **Peer-side** (leader only).
  """
  @spec random_group_key() :: group_key()
  def random_group_key, do: :crypto.strong_rand_bytes(@key_bytes)

  @doc """
  Derive the pairwise key shared by two peers in a room/epoch. **Peer-side.**

  `my_private` is the caller's X25519 private key; `peer_public` is the
  other peer's public key. The result is identical on both sides and known to
  neither the server nor any third peer.

  Returns `{:ok, key}` or `{:error, reason}` — never raises on bad input.
  """
  @spec pairwise_key(
          binary(),
          binary(),
          String.t(),
          non_neg_integer(),
          String.t(),
          String.t()
        ) :: {:ok, <<_::256>>} | {:error, term()}
  def pairwise_key(my_private, peer_public, room_id, epoch, my_peer_id, peer_id) do
    with :ok <- valid_key(my_private, :invalid_private_key),
         :ok <- valid_public_key(peer_public),
         :ok <- valid_ids(my_peer_id, peer_id),
         {:ok, shared} <- agree(my_private, peer_public) do
      salt = :crypto.hash(:sha256, ["pairwise|", room_id, "|", Integer.to_string(epoch)])

      info =
        @label_pairwise <>
          "|" <> Enum.join(Enum.sort([my_peer_id, peer_id]), "|")

      {:ok, hkdf(shared, salt, info)}
    end
  end

  @doc """
  Seal a room key for one peer. **Peer-side** (leader only).

  AAD binds the blob to the room, the epoch and both identities, so a blob
  cannot be replayed into another room, epoch or recipient.
  """
  @spec seal_group_key(
          group_key(),
          binary(),
          String.t(),
          non_neg_integer(),
          String.t(),
          String.t()
        ) :: {:ok, sealed_key()} | {:error, term()}
  def seal_group_key(group_key, pairwise, room_id, epoch, from_id, to_id) do
    with :ok <- valid_key(group_key, :invalid_group_key),
         :ok <- valid_key(pairwise, :invalid_pairwise_key),
         :ok <- valid_ids(from_id, to_id) do
      iv = :crypto.strong_rand_bytes(@iv_bytes)
      aad = seal_aad(room_id, epoch, from_id, to_id)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, pairwise, iv, group_key, aad, true)

      {:ok, {ciphertext, iv, tag}}
    end
  end

  @doc """
  Open a sealed room key. **Peer-side.**

  Returns `{:error, :open_failed}` for a wrong key, wrong epoch, wrong room or
  tampered blob — the AAD check covers all four.
  """
  @spec open_group_key(
          sealed_key(),
          binary(),
          String.t(),
          non_neg_integer(),
          String.t(),
          String.t()
        ) :: {:ok, group_key()} | {:error, term()}
  def open_group_key({ciphertext, iv, tag}, pairwise, room_id, epoch, from_id, to_id)
      when is_binary(ciphertext) and is_binary(iv) and is_binary(tag) do
    with :ok <- valid_key(pairwise, :invalid_pairwise_key),
         true <- byte_size(iv) == @iv_bytes and byte_size(tag) == @tag_bytes,
         aad = seal_aad(room_id, epoch, from_id, to_id),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, pairwise, iv, ciphertext, aad, tag, false),
         true <- byte_size(plaintext) == @key_bytes do
      {:ok, plaintext}
    else
      _ -> {:error, :open_failed}
    end
  end

  def open_group_key(blob, _pairwise, _room, _epoch, _from, _to) when is_binary(blob),
    do: {:error, :malformed_sealed_key}

  def open_group_key(_, _, _, _, _, _), do: {:error, :malformed_sealed_key}

  @doc """
  Encode a sealed key as the single binary that travels over the wire.

  Layout: `iv (12) || tag (16) || ciphertext (32)`.
  """
  @spec encode_sealed(sealed_key()) :: binary()
  def encode_sealed({ciphertext, iv, tag}), do: iv <> tag <> ciphertext

  @doc """
  Decode the wire form produced by `encode_sealed/1`.
  """
  @spec decode_sealed(binary()) :: {:ok, sealed_key()} | {:error, :malformed_sealed_key}
  def decode_sealed(<<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ct::binary>>)
      when byte_size(ct) > 0,
      do: {:ok, {ct, iv, tag}}

  def decode_sealed(_), do: {:error, :malformed_sealed_key}

  @doc """
  Derive the per-frame key from the room key. **Peer-side.**

  `counter` is the peer's monotonic frame counter; it is also the AAD field
  that makes replay detectable. Epoch is part of the salt so a key from one
  epoch can never decrypt another's frames.
  """
  @spec derive_frame_key(group_key(), non_neg_integer(), non_neg_integer()) :: group_key()
  def derive_frame_key(group_key, epoch, counter)
      when is_binary(group_key) and byte_size(group_key) == @key_bytes and
             is_integer(epoch) and is_integer(counter) do
    salt = :crypto.hash(:sha256, ["frame|", Integer.to_string(epoch)])
    hkdf(group_key, salt, @label_frame <> "|" <> Integer.to_string(counter))
  end

  @doc """
  The AAD that binds a sealed room key to its context. Public so clients can
  reproduce it exactly.
  """
  @spec seal_aad(String.t(), non_neg_integer(), String.t(), String.t()) :: binary()
  def seal_aad(room_id, epoch, from_id, to_id) do
    Enum.join([@label_group, room_id, Integer.to_string(epoch), from_id, to_id], "|")
  end

  # ── GenServer ──

  @impl true
  def init(_opts) do
    Logger.info("[E2EE] Key coordinator started — server holds no room keys")
    {:ok, %{rooms: %{}}}
  end

  @impl true
  def handle_call({:init_room, room_id}, _from, state) do
    if Map.has_key?(state.rooms, room_id) do
      {:reply, {:error, :room_exists}, state}
    else
      room = %{
        room_id: room_id,
        epoch: 0,
        peers: %{},
        sealed: %{},
        created_at: DateTime.utc_now(),
        rotated_at: nil
      }

      broadcast_lifecycle({:e2ee_room_init, %{room_id: room_id}})
      Logger.info("[E2EE] Room registered: #{room_id} (epoch 0, no key material)")

      {:reply, {:ok, %{epoch: 0}}, put_in(state, [:rooms, room_id], room)}
    end
  end

  @impl true
  def handle_call({:destroy_room, room_id}, _from, state) do
    case Map.pop(state.rooms, room_id) do
      {nil, _} ->
        {:reply, {:error, :no_room}, state}

      {_room, remaining} ->
        # Nothing secret is stored, so there is nothing to erase — but say so
        # plainly rather than implying a zeroing step that does not exist.
        broadcast_lifecycle({:e2ee_room_destroy, %{room_id: room_id}})
        Logger.info("[E2EE] Room deregistered: #{room_id}")
        {:reply, :ok, %{state | rooms: remaining}}
    end
  end

  @impl true
  def handle_call({:register_peer_key, room_id, peer_id, public_key}, _from, state) do
    with {:ok, room} <- fetch_room(state, room_id),
         :ok <- valid_public_key(public_key),
         :ok <- valid_peer_id(peer_id),
         :ok <- check_capacity(room) do
      existing = Map.get(room.peers, peer_id)

      cond do
        existing && existing.public_key == public_key ->
          # Re-registration (e.g. a reconnect) — nothing changes.
          {:reply, {:ok, %{epoch: room.epoch, peer_count: map_size(room.peers)}}, state}

        true ->
          peers =
            Map.put(room.peers, peer_id, %{public_key: public_key, joined_at: DateTime.utc_now()})

          room = %{room | peers: peers}
          room = maybe_rotate(room, reason: :membership_change)
          broadcast_lifecycle({:e2ee_room_init, %{room_id: room_id}})

          Logger.info(
            "[E2EE] Peer #{peer_id} registered in #{room_id} " <>
              "(epoch #{room.epoch}, peers #{map_size(peers)})"
          )

          {:reply, {:ok, %{epoch: room.epoch, peer_count: map_size(peers)}},
           put_in(state, [:rooms, room_id], room)}
      end
    else
      {:error, reason} ->
        Logger.warning("[E2EE] Rejected peer key for #{room_id}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove_peer, room_id, peer_id}, _from, state) do
    case fetch_room(state, room_id) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, room} ->
        peers = Map.delete(room.peers, peer_id)
        room = %{room | peers: peers} |> maybe_rotate(reason: :peer_left, force: true)

        if map_size(peers) == 0 do
          # Last peer out. Drop the room record rather than leaving an empty
          # shell behind: without this the map grows once per room ever joined,
          # for the lifetime of the node. A client that re-joins re-registers
          # through init_room/1 and starts at a fresh epoch.
          broadcast_lifecycle({:e2ee_room_destroy, %{room_id: room_id}})
          Logger.info("[E2EE] Room #{room_id} emptied — coordinator state dropped")

          {:reply, {:ok, room.epoch}, %{state | rooms: Map.delete(state.rooms, room_id)}}
        else
          broadcast_lifecycle({:e2ee_room_init, %{room_id: room_id}})

          Logger.info(
            "[E2EE] Peer #{peer_id} removed from #{room_id} — epoch #{room.epoch}, " <>
              "#{map_size(peers)} peer(s) remain"
          )

          {:reply, {:ok, room.epoch}, put_in(state, [:rooms, room_id], room)}
        end
    end
  end

  @impl true
  def handle_call({:request_rotation, room_id}, _from, state) do
    case fetch_room(state, room_id) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, room} ->
        room = rotate(room, :requested)
        broadcast_lifecycle({:e2ee_room_init, %{room_id: room_id}})
        {:reply, {:ok, room.epoch}, put_in(state, [:rooms, room_id], room)}
    end
  end

  @impl true
  def handle_call({:key_set, room_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        {:reply, {:error, :no_room}, state}

      room ->
        peers = Map.new(room.peers, fn {id, %{public_key: key}} -> {id, key} end)
        {:reply, {:ok, %{room_id: room_id, epoch: room.epoch, peers: peers}}, state}
    end
  end

  @impl true
  def handle_call({:publish_sealed, room_id, peer_id, epoch, blob}, _from, state) do
    with {:ok, room} <- fetch_room(state, room_id),
         :ok <- valid_peer_id(peer_id),
         true <- is_binary(blob) and byte_size(blob) > 0,
         true <- byte_size(blob) <= @max_sealed_bytes,
         true <- Map.has_key?(room.peers, peer_id),
         :ok <- check_epoch(room, epoch),
         leader <- leader_id(room),
         true <- peer_id == leader,
         nil <- Map.get(room.sealed, peer_id) do
      room = put_in(room, [:sealed, peer_id], %{epoch: epoch, from: leader, blob: blob})
      {:reply, :ok, put_in(state, [:rooms, room_id], room)}
    else
      false -> {:reply, {:error, :invalid_sealed_blob}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      %{epoch: ^epoch} -> {:reply, {:error, :already_published}, state}
      _ -> {:reply, {:error, :not_leader}, state}
    end
  end

  @impl true
  def handle_call({:sealed_for, room_id, peer_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        {:reply, {:error, :no_room}, state}

      room ->
        current = room.epoch

        case Map.get(room.sealed, peer_id) do
          %{epoch: ^current, from: from, blob: blob} ->
            {:reply, {:ok, %{epoch: current, from: from, blob: blob}}, state}

          %{epoch: _stale} ->
            {:reply, {:error, :stale_epoch}, state}

          nil ->
            {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:room_status, room_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        {:reply, {:error, :no_room}, state}

      room ->
        {:reply,
         {:ok,
          %{
            room_id: room_id,
            epoch: room.epoch,
            peers: map_size(room.peers),
            sealed_peers: map_size(room.sealed),
            # The point of the whole module, reported explicitly so an
            # operator can see it rather than infer it.
            key_custody: :peers,
            created_at: room.created_at,
            rotated_at: room.rotated_at
          }}, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Rotation ──

  # Bump the epoch and invalidate every sealed blob. Peers notice the epoch
  # change (via the lifecycle broadcast) and re-derive with fresh keys.
  defp rotate(room, reason) do
    if map_size(room.sealed) > 0 do
      Logger.info(
        "[E2EE] Rotating #{room.room_id} (#{reason}): epoch #{room.epoch} -> #{room.epoch + 1}"
      )
    end

    %{room | epoch: room.epoch + 1, sealed: %{}, rotated_at: DateTime.utc_now()}
  end

  # Membership changes only require a new epoch once a key has actually been
  # distributed; before that, peers are still gathering public keys for the
  # first epoch and bumping would just churn.
  defp maybe_rotate(room, opts) do
    force = Keyword.get(opts, :force, false)
    reason = Keyword.get(opts, :reason, :unspecified)

    if force or map_size(room.sealed) > 0 do
      rotate(room, reason)
    else
      room
    end
  end

  # ── Validation helpers ──

  defp fetch_room(state, room_id) do
    case Map.get(state.rooms, room_id) do
      nil -> {:error, :no_room}
      room -> {:ok, room}
    end
  end

  defp check_capacity(room) do
    if map_size(room.peers) >= @max_peers, do: {:error, :room_full}, else: :ok
  end

  defp check_epoch(room, epoch) do
    if epoch == room.epoch, do: :ok, else: {:error, :stale_epoch}
  end

  defp valid_key(key, _error) when is_binary(key) and byte_size(key) == @key_bytes, do: :ok
  defp valid_key(_, error), do: {:error, error}

  defp valid_public_key(key) when is_binary(key) and byte_size(key) == @key_bytes, do: :ok
  defp valid_public_key(_), do: {:error, :invalid_public_key}

  defp valid_peer_id(id) when is_binary(id) and byte_size(id) in 1..128, do: :ok
  defp valid_peer_id(_), do: {:error, :invalid_peer_id}

  defp valid_ids(a, b) do
    with :ok <- valid_peer_id(a), do: valid_peer_id(b)
  end

  # X25519 agreement that returns a tagged tuple instead of raising, and
  # rejects the all-zero secret produced by low-order points (RFC 7748 §6.1).
  defp agree(my_private, peer_public) do
    case :crypto.compute_key(:ecdh, peer_public, my_private, :x25519) do
      secret when is_binary(secret) and byte_size(secret) == @key_bytes ->
        if secret == :binary.copy(<<0>>, @key_bytes),
          do: {:error, :degenerate_shared_secret},
          else: {:ok, secret}

      _ ->
        {:error, :invalid_shared_secret}
    end
  rescue
    _ -> {:error, :invalid_public_key}
  end

  # HKDF-SHA256 (RFC 5869), extract + one expand block. Local rather than via
  # the coprocessor so the peer-side helpers have no runtime dependency.
  defp hkdf(ikm, salt, info) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1::8>>)
  end

  defp broadcast_lifecycle(event) do
    Phoenix.PubSub.broadcast(Burble.PubSub, @lifecycle_topic, event)
  catch
    # PubSub is absent in isolated unit tests; the broadcast is advisory.
    _kind, _reason -> :ok
  end
end
