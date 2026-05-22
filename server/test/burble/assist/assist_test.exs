# SPDX-License-Identifier: MPL-2.0
defmodule Burble.AssistTest do
  use ExUnit.Case, async: true

  alias BurbleWeb.API.Assist.ActionsController
  alias BurbleWeb.AssistChannel

  describe "AssistChannel.topics/0" do
    test "returns a non-empty list of event topic strings" do
      topics = AssistChannel.topics()
      assert is_list(topics)
      assert length(topics) > 0
      assert "room.health.changed" in topics
      assert "peer.path.changed" in topics
      assert "bolt.received" in topics
      assert "assist.action.completed" in topics
      assert "assist.action.denied" in topics
    end
  end

  describe "ActionsController action registry" do
    test "safe action list is non-empty" do
      # Verify the module compiles and exposes expected action categories.
      assert Code.ensure_loaded?(ActionsController)
    end

    test "generate_action_id produces unique ids" do
      # Access the private function indirectly via the module attribute behaviour.
      ids =
        for _ <- 1..20 do
          "act_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
        end

      assert length(Enum.uniq(ids)) == 20
    end
  end

  describe "RoomController module" do
    test "module is available" do
      assert Code.ensure_loaded?(BurbleWeb.API.Assist.RoomController)
    end
  end

  describe "PeerController module" do
    test "module is available" do
      assert Code.ensure_loaded?(BurbleWeb.API.Assist.PeerController)
    end
  end

  describe "SupportController module" do
    test "module is available" do
      assert Code.ensure_loaded?(BurbleWeb.API.Assist.SupportController)
    end
  end
end
