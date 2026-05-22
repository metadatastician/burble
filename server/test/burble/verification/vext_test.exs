# SPDX-License-Identifier: MPL-2.0

defmodule Burble.Verification.VextTest do
  use ExUnit.Case, async: true

  alias Burble.Verification.Vext

  describe "init_chain/1" do
    test "creates genesis state" do
      chain = Vext.init_chain("test_channel")
      assert chain.channel_id == "test_channel"
      assert chain.position == 0
      assert is_binary(chain.latest_hash)
    end
  end

  describe "create_header/4" do
    test "produces valid header with chain link" do
      chain = Vext.init_chain("ch1")
      timestamp = DateTime.utc_now()

      {header, new_chain} = Vext.create_header("Hello, world!", "user_1", timestamp, chain)

      assert is_binary(header.article_hash)
      assert header.previous_hash == chain.latest_hash
      assert header.chain_position == 1
      assert is_binary(header.chain_hash)
      assert is_binary(header.server_signature)
      assert new_chain.position == 1
      assert new_chain.latest_hash == header.chain_hash
    end

    test "chain links are sequential" do
      chain = Vext.init_chain("ch1")
      ts = DateTime.utc_now()

      {h1, chain} = Vext.create_header("First", "user_1", ts, chain)
      {h2, chain} = Vext.create_header("Second", "user_1", ts, chain)
      {h3, _chain} = Vext.create_header("Third", "user_1", ts, chain)

      assert h1.chain_position == 1
      assert h2.chain_position == 2
      assert h3.chain_position == 3
      assert h2.previous_hash == h1.chain_hash
      assert h3.previous_hash == h2.chain_hash
    end
  end

  describe "verify_article/5" do
    test "verifies a valid article" do
      chain = Vext.init_chain("ch1")
      ts = DateTime.utc_now()
      body = "Test message"
      author = "user_1"

      {header, _new_chain} = Vext.create_header(body, author, ts, chain)

      assert {:ok, :verified} =
               Vext.verify_article(body, author, ts, header, chain.latest_hash)
    end

    test "detects content tampering" do
      chain = Vext.init_chain("ch1")
      ts = DateTime.utc_now()

      {header, _} = Vext.create_header("Original", "user_1", ts, chain)

      assert {:error, :hash_mismatch} =
               Vext.verify_article("Tampered", "user_1", ts, header, chain.latest_hash)
    end

    test "detects chain break" do
      chain = Vext.init_chain("ch1")
      ts = DateTime.utc_now()

      {header, _} = Vext.create_header("Message", "user_1", ts, chain)

      assert {:error, :chain_broken} =
               Vext.verify_article("Message", "user_1", ts, header, "wrong_previous_hash")
    end
  end

  describe "verify_feed/1" do
    test "verifies a valid feed" do
      chain = Vext.init_chain("ch1")
      ts = DateTime.utc_now()

      {h1, chain} = Vext.create_header("First", "user_1", ts, chain)
      {h2, chain} = Vext.create_header("Second", "user_2", ts, chain)
      {h3, _chain} = Vext.create_header("Third", "user_1", ts, chain)

      feed = [
        {"First", "user_1", ts, h1},
        {"Second", "user_2", ts, h2},
        {"Third", "user_1", ts, h3}
      ]

      assert {:ok, :verified, 3} = Vext.verify_feed(feed)
    end

    test "detects tampering in middle of feed" do
      chain = Vext.init_chain("ch1")
      ts = DateTime.utc_now()

      {h1, chain} = Vext.create_header("First", "user_1", ts, chain)
      {h2, chain} = Vext.create_header("Second", "user_2", ts, chain)
      {h3, _chain} = Vext.create_header("Third", "user_1", ts, chain)

      feed = [
        {"First", "user_1", ts, h1},
        {"TAMPERED", "user_2", ts, h2},  # Content changed.
        {"Third", "user_1", ts, h3}
      ]

      assert {:error, :chain_broken, errors} = Vext.verify_feed(feed)
      assert length(errors) > 0
    end
  end
end
