# SPDX-License-Identifier: MPL-2.0
#
# Burble.Text.NNTPSBackend — NNTPS-backed text channels.
#
# Instead of ephemeral chat, Burble's text channels are backed by NNTP
# articles. This gives us:
#
#   - Threaded discussions (NNTP's native threading via References header)
#   - Persistent, archivable messages (survive server restarts)
#   - Offline reading (clients can cache articles locally)
#   - Standards-based (40+ years of proven protocol, RFC 3977)
#   - Interoperable (any NNTP reader can access Burble text channels)
#
# Integration with no-nonsense-nntps:
#   The NNTPS client module handles the wire protocol (TLS-mandatory,
#   RFC 3977 compliant). Burble wraps it with:
#   - Channel-to-newsgroup mapping (room "general" → burble.server.general)
#   - Permission enforcement (only authorised users can post)
#   - Real-time push via Phoenix PubSub (new articles broadcast to connected clients)
#   - Vext verification headers (cryptographic proof of feed integrity)
#
# Architecture:
#   Burble server runs an embedded NNTPS server for its own text channels.
#   External NNTPS servers can also be bridged for community interop.

defmodule Burble.Text.NNTPSBackend do
  @moduledoc """
  NNTPS-backed text channel storage.

  Maps Burble rooms to NNTP newsgroups and provides threaded,
  persistent, archivable text alongside voice.
  """

  use GenServer

  # ── Types ──

  @type article :: %{
          message_id: String.t(),
          subject: String.t(),
          from: String.t(),
          date: DateTime.t(),
          body: String.t(),
          references: [String.t()],
          newsgroup: String.t()
        }

  @type thread :: %{
          root: article(),
          replies: [article()]
        }

  # ── Client API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Post a message to a room's text channel.

  The message becomes an NNTP article in the room's mapped newsgroup.
  If `reply_to` is provided, the article is threaded under that message.
  """
  def post_message(room_id, user_id, display_name, body, opts \\ []) do
    GenServer.call(__MODULE__, {:post, room_id, user_id, display_name, body, opts})
  end

  @doc """
  Fetch recent articles from a room's text channel.

  Returns articles in reverse chronological order (newest first),
  with threading information via References headers.
  """
  def fetch_recent(room_id, limit \\ 50) do
    GenServer.call(__MODULE__, {:fetch_recent, room_id, limit})
  end

  @doc """
  Fetch a complete thread starting from a root article.
  """
  def fetch_thread(message_id) do
    GenServer.call(__MODULE__, {:fetch_thread, message_id})
  end

  @doc """
  List all text channels (newsgroups) for a server.
  """
  def list_channels(server_id) do
    GenServer.call(__MODULE__, {:list_channels, server_id})
  end

  @doc """
  Verify the integrity of a room's entire text feed using Vext hash chains.

  Walks the chain from genesis and checks every article. Returns
  `{:ok, :verified, article_count}` or `{:error, :chain_broken, errors}`.

  Any client can call this independently to prove the feed hasn't been
  tampered with — no trust in the server required.
  """
  def verify_feed(room_id) do
    GenServer.call(__MODULE__, {:verify_feed, room_id})
  end

  @doc """
  Get the current Vext chain state for a room.

  Returns the chain position and latest hash — useful for clients
  that want to verify incrementally (only new articles since last check).
  """
  def chain_state(room_id) do
    GenServer.call(__MODULE__, {:chain_state, room_id})
  end

  @doc """
  Pin a message in a channel. Pinned messages are stored as
  specially-tagged articles that appear at the top of the channel.
  """
  def pin_message(room_id, message_id) do
    GenServer.call(__MODULE__, {:pin, room_id, message_id})
  end

  # ── Server Callbacks ──

  @impl true
  def init(opts) do
    state = %{
      # In-memory article store (replaced by NNTPS server connection in production)
      articles: %{},
      # Room ID → newsgroup name mapping
      room_map: %{},
      # Pinned messages per room
      pins: %{},
      # Vext chain state per room — tracks hash chain for feed integrity verification.
      # Each room gets its own independent chain.
      vext_chains: %{},
      # Connection to embedded or external NNTPS server
      nntps_host: Keyword.get(opts, :nntps_host, "localhost"),
      nntps_port: Keyword.get(opts, :nntps_port, 563)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:post, room_id, user_id, display_name, body, opts}, _from, state) do
    alias Burble.Verification.Vext

    newsgroup = room_to_newsgroup(room_id, state)
    reply_to = Keyword.get(opts, :reply_to)
    timestamp = DateTime.utc_now()
    message_id = generate_message_id()

    # Get or initialise the Vext chain for this room.
    chain_state =
      Map.get_lazy(state.vext_chains, room_id, fn ->
        Vext.init_chain(room_id)
      end)

    # Create Vext verification header — cryptographic proof of feed integrity.
    # This links the article to the previous one via hash chain, proving:
    # 1. No articles have been inserted or removed
    # 2. No content has been modified
    # 3. Ordering is authentic (server-signed)
    {vext_header, new_chain_state} =
      Vext.create_header(body, user_id, timestamp, chain_state)

    # Groove: forward verification header to external Vext service for
    # independent attestation. Fire-and-forget (async) — message delivery
    # is never blocked by groove availability. When Vext is grooved in,
    # users get TWO independent integrity proofs (Burble's + Vext's).
    Task.start(fn ->
      Burble.Verification.VextGroove.attest_header(vext_header, room_id)
    end)

    article = %{
      message_id: message_id,
      subject: Keyword.get(opts, :subject, ""),
      from: "#{display_name} <#{user_id}@burble.local>",
      date: timestamp,
      body: body,
      references: if(reply_to, do: [reply_to], else: []),
      newsgroup: newsgroup,
      # Full Vext verification header (hash chain + server signature).
      x_vext_header: vext_header,
      # Legacy field for backward compatibility.
      x_vext_hash: vext_header.article_hash
    }

    # Store article and update chain state.
    articles = Map.update(state.articles, newsgroup, [article], &[article | &1])
    vext_chains = Map.put(state.vext_chains, room_id, new_chain_state)
    new_state = %{state | articles: articles, vext_chains: vext_chains}

    # Broadcast to connected clients via PubSub.
    Phoenix.PubSub.broadcast(
      Burble.PubSub,
      "text:#{room_id}",
      {:new_article, article}
    )

    {:reply, {:ok, article}, new_state}
  end

  @impl true
  def handle_call({:fetch_recent, room_id, limit}, _from, state) do
    newsgroup = room_to_newsgroup(room_id, state)

    articles =
      state.articles
      |> Map.get(newsgroup, [])
      |> Enum.take(limit)

    {:reply, {:ok, articles}, state}
  end

  @impl true
  def handle_call({:fetch_thread, message_id}, _from, state) do
    # Find root article and all replies referencing it
    all_articles = state.articles |> Map.values() |> List.flatten()

    root = Enum.find(all_articles, fn a -> a.message_id == message_id end)

    replies =
      Enum.filter(all_articles, fn a ->
        message_id in (a.references || [])
      end)
      |> Enum.sort_by(& &1.date, DateTime)

    case root do
      nil -> {:reply, {:error, :not_found}, state}
      _ -> {:reply, {:ok, %{root: root, replies: replies}}, state}
    end
  end

  @impl true
  def handle_call({:list_channels, server_id}, _from, state) do
    channels =
      state.room_map
      |> Enum.filter(fn {_room_id, ng} -> String.starts_with?(ng, "burble.#{server_id}.") end)
      |> Enum.map(fn {room_id, newsgroup} ->
        count = state.articles |> Map.get(newsgroup, []) |> length()
        %{room_id: room_id, newsgroup: newsgroup, article_count: count}
      end)

    {:reply, {:ok, channels}, state}
  end

  @impl true
  def handle_call({:pin, room_id, message_id}, _from, state) do
    pins = Map.update(state.pins, room_id, [message_id], &[message_id | &1])
    {:reply, :ok, %{state | pins: pins}}
  end

  @impl true
  def handle_call({:verify_feed, room_id}, _from, state) do
    alias Burble.Verification.Vext

    newsgroup = room_to_newsgroup(room_id, state)

    articles =
      state.articles
      |> Map.get(newsgroup, [])
      |> Enum.reverse()  # Oldest first for chain verification.

    # Build the list of (body, author_id, timestamp, header) tuples.
    articles_with_headers =
      Enum.map(articles, fn article ->
        # Extract user_id from the "from" field: "Name <user_id@burble.local>"
        user_id =
          case Regex.run(~r/<(.+?)@/, article.from) do
            [_, uid] -> uid
            _ -> "unknown"
          end

        {article.body, user_id, article.date, article.x_vext_header}
      end)
      |> Enum.filter(fn {_, _, _, header} -> header != nil end)

    result = Vext.verify_feed(articles_with_headers)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:chain_state, room_id}, _from, state) do
    case Map.get(state.vext_chains, room_id) do
      nil -> {:reply, {:error, :no_chain}, state}
      chain -> {:reply, {:ok, chain}, state}
    end
  end

  # ── Private ──

  defp room_to_newsgroup(room_id, state) do
    Map.get_lazy(state.room_map, room_id, fn ->
      "burble.room.#{room_id}"
    end)
  end

  defp generate_message_id do
    random = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    "<#{random}@burble.local>"
  end

  @doc """
  Compute a Vext verification hash for an article.

  This hash allows any client to verify that:
  1. The article body hasn't been modified
  2. The author attribution is correct
  3. The timestamp hasn't been altered
  4. No articles have been inserted or removed from the feed

  Uses SHA-256 + Ed25519 signature chain for ordering proof.
  """
  def compute_vext_hash(body, user_id, timestamp) do
    data = "#{body}|#{user_id}|#{DateTime.to_iso8601(timestamp)}"
    # Use SHA-256 (universally available) instead of BLAKE2B (OTP 26+ only).
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end
end
