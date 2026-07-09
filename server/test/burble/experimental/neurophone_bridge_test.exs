# SPDX-License-Identifier: MPL-2.0
#
# Lifecycle tests for the EXPERIMENTAL neurophone presence bridge (ADR-0015).
# No radio, no sockets — just start / cast events / stats / forward / stop.

defmodule Burble.Bridges.NeurophoneTest do
  use ExUnit.Case, async: true

  alias Burble.Bridges.Neurophone

  describe "neurophone bridge stub" do
    test "is a loadable GenServer with start_link/1" do
      assert Code.ensure_loaded?(Neurophone)
      assert function_exported?(Neurophone, :start_link, 1)

      behaviours =
        Neurophone.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert GenServer in behaviours
    end

    test "starts, tracks counters, forwards to the sink, and stops cleanly" do
      {:ok, pid} = Neurophone.start_link(room_id: "test-room", sink: self())
      assert Process.alive?(pid)

      assert Neurophone.get_stats(pid) == %{room_id: "test-room", knocks: 0, presences: 0}

      GenServer.cast(pid, {:knock_observed, %{ts: 1_767_225_600, nonce_hex: "0102030405ff"}})
      assert_receive {:neurophone_knock, "test-room", %{nonce_hex: "0102030405ff"}}

      GenServer.cast(pid, {:presence_resolved, %{contact_id: "c", epoch: 1_963_584}})
      assert_receive {:neurophone_presence, "test-room", %{contact_id: "c"}}

      assert Neurophone.get_stats(pid) == %{room_id: "test-room", knocks: 1, presences: 1}

      assert :ok = Neurophone.stop(pid)
      refute Process.alive?(pid)
    end

    test "runs without a sink (counters still advance)" do
      {:ok, pid} = Neurophone.start_link(room_id: "no-sink")
      GenServer.cast(pid, {:knock_observed, %{ts: 1}})
      # give the cast time to be processed
      _ = Neurophone.get_stats(pid)
      assert %{knocks: 1, presences: 0} = Neurophone.get_stats(pid)
      assert :ok = Neurophone.stop(pid)
    end
  end
end
