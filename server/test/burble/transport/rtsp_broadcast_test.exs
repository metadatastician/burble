# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# EXPERIMENTAL feature test: server-mediated RTSP broadcast egress.
#
# Proves the revived SFU→RTSP path end to end at the unit level: when the
# `:rtsp_broadcast` flag is on, a Media.Engine session created with an RTSP
# mountpoint fans distribute_rtp packets out to RTSP subscribers, and when the
# flag is off the session carries no mountpoint and nothing is injected.

defmodule Burble.Transport.RTSPBroadcastTest do
  use ExUnit.Case, async: false

  alias Burble.Media.Engine
  alias Burble.Transport.RTSP

  setup do
    original = Application.get_env(:burble, :rtsp_broadcast, false)
    on_exit(fn -> Application.put_env(:burble, :rtsp_broadcast, original) end)
    :ok
  end

  defp unique_room, do: "bcast-#{System.unique_integer([:positive])}"

  test "flag ON: distribute_rtp reaches an RTSP subscriber via the mountpoint" do
    Application.put_env(:burble, :rtsp_broadcast, true)
    room_id = unique_room()

    # Register the broadcast mountpoint on the app-owned RTSP, subscribe this
    # test process to it, then create the Engine session carrying that path.
    {:ok, mountpoint} = RTSP.register_mountpoint(room_id, :speaker)
    :ok = RTSP.subscribe(mountpoint, self())
    {:ok, ^room_id} = Engine.create_room_session(room_id, rtsp_mountpoint: mountpoint)

    packet = :crypto.strong_rand_bytes(48)
    Engine.distribute_rtp(room_id, "broadcaster", packet)

    # RTSP fans injected packets to subscribers as {:rtsp_rtp, path, packet}.
    assert_receive {:rtsp_rtp, ^mountpoint, ^packet}, 1_000

    Engine.destroy_room_session(room_id)
    RTSP.remove_mountpoint(mountpoint)
  end

  test "flag OFF: session carries no mountpoint and nothing is injected" do
    Application.put_env(:burble, :rtsp_broadcast, false)
    room_id = unique_room()

    {:ok, mountpoint} = RTSP.register_mountpoint(room_id, :speaker)
    :ok = RTSP.subscribe(mountpoint, self())
    # Even though a mountpoint is passed, the flag is off, so the session must
    # not store it — the default P2P path is unchanged.
    {:ok, ^room_id} = Engine.create_room_session(room_id, rtsp_mountpoint: mountpoint)

    packet = :crypto.strong_rand_bytes(48)
    Engine.distribute_rtp(room_id, "broadcaster", packet)

    refute_receive {:rtsp_rtp, ^mountpoint, _packet}, 300

    Engine.destroy_room_session(room_id)
    RTSP.remove_mountpoint(mountpoint)
  end
end
