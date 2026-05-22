# SPDX-License-Identifier: MPL-2.0
#
# Burble Accessibility E2E Test.
#
# Verifies the "Blind Navigation" journey:
#   1. A user joins a room.
#   2. The system generates a voice-first announcement telemetry event.
#   3. A user leaves a room.
#   4. The system generates a departure announcement.

defmodule Burble.Accessibility.E2ETest do
  use ExUnit.Case, async: false # Async false to ensure telemetry attachment cleanup
  alias Burble.Rooms.RoomManager

  setup do
    # Attach to the accessibility announcement telemetry event
    parent = self()
    handler_id = "accessibility-test-handler"
    
    :telemetry.attach(
      handler_id,
      [:burble, :accessibility, :announce],
      fn _event, measurements, metadata, _config ->
        send(parent, {:accessibility_announce, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    
    room_id = "a11y-test-room"
    user_id = "user-a11y"
    
    {:ok, room_id: room_id, user_id: user_id}
  end

  test "joining and leaving a room triggers voice announcements", %{room_id: room_id, user_id: user_id} do
    # 1. Join room
    assert {:ok, _} = RoomManager.join(room_id, user_id, %{display_name: "AccessibilityUser"})
    
    # 2. Verify join announcement
    assert_receive {:accessibility_announce, %{text: announcement}, _}, 2000
    assert announcement =~ "AccessibilityUser joined"
    assert announcement =~ "Room a11y-test-room"

    # 3. Leave room
    assert :ok = Burble.Rooms.Room.leave(room_id, user_id)

    # 4. Verify leave announcement
    assert_receive {:accessibility_announce, %{text: announcement}, _}, 2000
    assert announcement =~ "AccessibilityUser left"
  end
end
