# SPDX-License-Identifier: MPL-2.0
#
# Tests for Burble.Presence — Phoenix.Presence wrapper.
#
# The full Presence API requires PubSub to be running (which it is when
# the application is started via test_helper.exs). Tests verify that
# the module is correctly set up and that the Phoenix.Presence callbacks
# work as expected against the live PubSub.

defmodule Burble.PresenceTest do
  use ExUnit.Case, async: false

  @topic "test:presence:#{__MODULE__}"

  describe "module" do
    test "Burble.Presence is loaded" do
      assert Code.ensure_loaded?(Burble.Presence)
    end

    test "exposes track/3 (Phoenix.Presence callback)" do
      exports = Burble.Presence.__info__(:functions)
      assert Keyword.has_key?(exports, :track)
    end

    test "exposes list/1 (Phoenix.Presence callback)" do
      exports = Burble.Presence.__info__(:functions)
      assert Keyword.has_key?(exports, :list)
    end
  end

  describe "track and list" do
    test "list/1 returns empty map for an unused topic" do
      result = Burble.Presence.list(@topic <> ":empty")
      assert result == %{}
    end

    test "track/3 adds a presence entry visible via list/1" do
      topic = @topic <> ":track-#{System.unique_integer()}"
      user_id = "test-user-#{System.unique_integer()}"

      # Subscribe the test process so track/3 has a valid socket-like pid.
      Phoenix.PubSub.subscribe(Burble.PubSub, topic)

      {:ok, _ref} =
        Burble.Presence.track(self(), topic, user_id, %{display_name: "Tester"})

      # Presence diffs arrive asynchronously; list/1 reflects current state.
      presences = Burble.Presence.list(topic)
      assert Map.has_key?(presences, user_id)

      user_meta = get_in(presences, [user_id, :metas])
      assert is_list(user_meta)
      assert length(user_meta) >= 1
      assert hd(user_meta).display_name == "Tester"
    end
  end
end
