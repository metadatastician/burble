# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# E2E round-trip tests for Burble.Text.NNTPSBackend.
#
# Exercises the full text-channel path:
#   post_message → in-memory store → fetch_recent / fetch_thread → Vext chain verify
#
# Infrastructure notes:
#   - NNTPSBackend is a GenServer with an in-memory article store.  No real
#     NNTP server connection is made in tests; the nntps_host/nntps_port opts
#     are stored but never dialled inside the callbacks exercised here.
#   - VextGroove.attest_header is called fire-and-forget via Task.start inside
#     handle_call({:post, …}).  When port 6480 is unreachable the TCP connect
#     returns {:error, :econnrefused} and the task exits silently — this is
#     expected in CI and does not affect assertions.
#   - Tests run with async: false because NNTPSBackend is a named GenServer
#     (__MODULE__).  Each test gets a fresh instance via start_supervised!.
#
# Vext chain verification:
#   verify_feed/1 walks the chain from genesis and checks every article.
#   It expects articles in oldest-first order; NNTPSBackend.verify_feed/1
#   reverses the in-memory list (which is newest-first) before walking.

defmodule Burble.Text.NNTPSBackendTest do
  use ExUnit.Case, async: false

  import Burble.TestHelpers

  alias Burble.Text.NNTPSBackend
  alias Burble.Verification.Vext

  # ---------------------------------------------------------------------------
  # Setup — fresh GenServer for every test
  # ---------------------------------------------------------------------------

  setup do
    # PubSub must be running because post_message broadcasts to "text:<room_id>".
    Application.ensure_all_started(:phoenix_pubsub)
    ensure_started({Phoenix.PubSub, name: Burble.PubSub})

    # Start a fresh NNTPSBackend instance.  start_supervised! gives ExUnit
    # ownership so it is torn down (and the name released) after each test.
    ensure_started(NNTPSBackend)

    :ok
  end

  # ---------------------------------------------------------------------------
  # 1. Post + fetch round-trip
  # ---------------------------------------------------------------------------

  describe "post + fetch round-trip" do
    test "posted message is returned by fetch_recent with correct fields" do
      room_id = generate_room_id()
      user_id = generate_user_id()
      display_name = "Alice"
      body = "Hello, Burble text channel!"

      assert {:ok, article} = NNTPSBackend.post_message(room_id, user_id, display_name, body)

      # post_message must return the stored article immediately.
      assert article.body == body
      assert article.message_id =~ ~r/<[0-9a-f]+@burble\.local>/
      assert %DateTime{} = article.date
      assert article.newsgroup == "burble.room.#{room_id}"

      # The "from" field encodes both display_name and user_id.
      assert article.from == "#{display_name} <#{user_id}@burble.local>"

      # fetch_recent must return the same article.
      assert {:ok, [fetched]} = NNTPSBackend.fetch_recent(room_id)

      assert fetched.message_id == article.message_id
      assert fetched.body == body
      assert fetched.from == "#{display_name} <#{user_id}@burble.local>"
    end

    test "fetch_recent respects the limit parameter" do
      room_id = generate_room_id()

      for i <- 1..10 do
        NNTPSBackend.post_message(room_id, "user-#{i}", "User #{i}", "Message #{i}")
      end

      assert {:ok, five} = NNTPSBackend.fetch_recent(room_id, 5)
      assert length(five) == 5
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Threading — post root + reply, verify fetch_thread returns both
  # ---------------------------------------------------------------------------

  describe "threading" do
    test "fetch_thread returns root and reply in order" do
      room_id = generate_room_id()

      # Post root message.
      {:ok, root} =
        NNTPSBackend.post_message(room_id, "user-a", "Alice", "Root message",
          subject: "Discussion topic"
        )

      root_id = root.message_id

      # Post a reply referencing the root.
      {:ok, reply} =
        NNTPSBackend.post_message(room_id, "user-b", "Bob", "Reply to root",
          reply_to: root_id,
          subject: "Re: Discussion topic"
        )

      assert reply.references == [root_id]

      # fetch_thread must find the root and include the reply.
      assert {:ok, thread} = NNTPSBackend.fetch_thread(root_id)

      assert thread.root.message_id == root_id
      assert thread.root.body == "Root message"

      assert length(thread.replies) == 1
      assert hd(thread.replies).message_id == reply.message_id
      assert hd(thread.replies).body == "Reply to root"
    end

    test "fetch_thread returns replies in chronological order" do
      room_id = generate_room_id()

      {:ok, root} = NNTPSBackend.post_message(room_id, "user-a", "Alice", "Root")
      root_id = root.message_id

      {:ok, reply1} =
        NNTPSBackend.post_message(room_id, "user-b", "Bob", "First reply",
          reply_to: root_id
        )

      {:ok, reply2} =
        NNTPSBackend.post_message(room_id, "user-c", "Carol", "Second reply",
          reply_to: root_id
        )

      assert {:ok, thread} = NNTPSBackend.fetch_thread(root_id)

      # replies are sorted by date ascending inside fetch_thread.
      reply_ids = Enum.map(thread.replies, & &1.message_id)
      assert reply_ids == [reply1.message_id, reply2.message_id]
    end

    test "fetch_thread returns error for unknown message_id" do
      assert {:error, :not_found} = NNTPSBackend.fetch_thread("<nonexistent@burble.local>")
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Empty room
  # ---------------------------------------------------------------------------

  describe "empty room" do
    test "fetch_recent on a room with no messages returns empty list" do
      room_id = generate_room_id()
      assert {:ok, []} = NNTPSBackend.fetch_recent(room_id)
    end

    test "chain_state returns error for a room that has never had a message" do
      room_id = generate_room_id()
      assert {:error, :no_chain} = NNTPSBackend.chain_state(room_id)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Message ordering — 5 messages posted rapidly, fetch returns oldest last
  # ---------------------------------------------------------------------------

  describe "message ordering" do
    test "fetch_recent returns messages in newest-first (reverse-chronological) order" do
      room_id = generate_room_id()

      bodies = for i <- 1..5, do: "Message #{i}"

      for body <- bodies do
        {:ok, _} = NNTPSBackend.post_message(room_id, "user-x", "Xeno", body)
      end

      assert {:ok, articles} = NNTPSBackend.fetch_recent(room_id)
      assert length(articles) == 5

      fetched_bodies = Enum.map(articles, & &1.body)

      # Articles are stored newest-first (prepended), so fetch_recent returns
      # them in that order.
      assert fetched_bodies == Enum.reverse(bodies),
             "Expected newest-first order, got #{inspect(fetched_bodies)}"
    end

    test "each of the 5 messages has a unique message_id" do
      room_id = generate_room_id()

      ids =
        for i <- 1..5 do
          {:ok, article} = NNTPSBackend.post_message(room_id, "user-x", "Xeno", "Msg #{i}")
          article.message_id
        end

      assert length(Enum.uniq(ids)) == 5, "All message_ids must be unique"
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Vext hash chain integrity
  # ---------------------------------------------------------------------------

  describe "Vext hash chain" do
    test "each article receives a vext header with a chain position" do
      room_id = generate_room_id()

      {:ok, a1} = NNTPSBackend.post_message(room_id, "user-a", "Alice", "First")
      {:ok, a2} = NNTPSBackend.post_message(room_id, "user-b", "Bob", "Second")
      {:ok, a3} = NNTPSBackend.post_message(room_id, "user-c", "Carol", "Third")

      assert a1.x_vext_header.chain_position == 1
      assert a2.x_vext_header.chain_position == 2
      assert a3.x_vext_header.chain_position == 3
    end

    test "each article's previous_hash links to the prior article's chain_hash" do
      room_id = generate_room_id()

      {:ok, a1} = NNTPSBackend.post_message(room_id, "user-a", "Alice", "First")
      {:ok, a2} = NNTPSBackend.post_message(room_id, "user-b", "Bob", "Second")
      {:ok, a3} = NNTPSBackend.post_message(room_id, "user-c", "Carol", "Third")

      # a1's previous_hash is the genesis hash (all-zeros).
      assert a1.x_vext_header.previous_hash ==
               "0000000000000000000000000000000000000000000000000000000000000000"

      # Each subsequent article's previous_hash must equal the prior chain_hash.
      assert a2.x_vext_header.previous_hash == a1.x_vext_header.chain_hash
      assert a3.x_vext_header.previous_hash == a2.x_vext_header.chain_hash
    end

    test "verify_feed returns :ok after posting multiple messages" do
      room_id = generate_room_id()

      NNTPSBackend.post_message(room_id, "user-a", "Alice", "First message")
      NNTPSBackend.post_message(room_id, "user-b", "Bob", "Second message")
      NNTPSBackend.post_message(room_id, "user-c", "Carol", "Third message")

      assert {:ok, :verified, 3} = NNTPSBackend.verify_feed(room_id)
    end

    test "verify_feed returns :ok for a single-message room" do
      room_id = generate_room_id()

      NNTPSBackend.post_message(room_id, "user-a", "Alice", "Only message")

      assert {:ok, :verified, 1} = NNTPSBackend.verify_feed(room_id)
    end

    test "verify_feed returns :ok for an empty room (zero articles)" do
      room_id = generate_room_id()

      # No articles posted — verify_feed on an empty newsgroup must succeed
      # with count 0 (the chain walk completes trivially).
      assert {:ok, :verified, 0} = NNTPSBackend.verify_feed(room_id)
    end

    test "chain_state reflects the latest chain position after posts" do
      room_id = generate_room_id()

      NNTPSBackend.post_message(room_id, "user-a", "Alice", "Msg 1")
      NNTPSBackend.post_message(room_id, "user-b", "Bob", "Msg 2")

      assert {:ok, chain} = NNTPSBackend.chain_state(room_id)
      assert chain.position == 2
      assert is_binary(chain.latest_hash)
      assert chain.channel_id == room_id
    end

    test "Vext.verify_article validates an article header directly" do
      # Unit-level check that the header created by NNTPSBackend is consumable
      # by Vext.verify_article — closing the loop between the two modules.
      room_id = generate_room_id()

      {:ok, article} =
        NNTPSBackend.post_message(room_id, "user-a", "Alice", "Verify me")

      header = article.x_vext_header

      # Reconstruct user_id the same way verify_feed does.
      [_, user_id] = Regex.run(~r/<(.+?)@/, article.from)

      genesis = "0000000000000000000000000000000000000000000000000000000000000000"

      assert {:ok, :verified} =
               Vext.verify_article(
                 article.body,
                 user_id,
                 article.date,
                 header,
                 genesis
               )
    end
  end
end
