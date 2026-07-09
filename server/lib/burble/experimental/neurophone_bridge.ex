# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Bridges.Neurophone — EXPERIMENTAL neurophone presence-event forwarder.
#
# EXPERIMENTAL (ADR-0015, Phase 0): this module is NOT started by the
# supervision tree, holds no radio, opens no sockets, and does no BLE. It is
# the server-side stub for the eventual (Phase 4) forwarder that relays decoded
# BLE presence events — knocks and contact resolutions, per the format frozen
# in ADR-0015 / Burble.Presence.BleSpa — from a neurophone sensor into a Burble
# room. It lives under experimental/ per the CONTRIBUTING liveness invariant
# (supervised | invoked | experimental), mirroring experimental/mumble_bridge.ex.

defmodule Burble.Bridges.Neurophone do
  @moduledoc """
  EXPERIMENTAL — neurophone presence-event forwarder (stub).

  Not started by the supervision tree; no radio, no sockets (ADR-0015 Phase 0).
  Accepts already-decoded presence events and forwards them to an optional
  `sink` pid while tracking counters. The actual BLE decode happens on the
  neurophone device against the frozen wire format
  (`.machine_readable/descriptiles/{ble-spa-knock,nearby-presence}.a2ml`); this
  is only the server-side rendezvous point that a later phase will wire in.

  ## Starting a bridge

      {:ok, pid} = Burble.Bridges.Neurophone.start_link(room_id: "r1", sink: self())
      GenServer.cast(pid, {:knock_observed, %{ts: 1_767_225_600, nonce_hex: "..."}})
      Burble.Bridges.Neurophone.get_stats(pid)
      #=> %{room_id: "r1", knocks: 1, presences: 0}
  """

  use GenServer
  require Logger

  # ── Client API ──

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, init_opts} = Keyword.pop(opts, :name)
    if name, do: GenServer.start_link(__MODULE__, init_opts, name: name),
      else: GenServer.start_link(__MODULE__, init_opts)
  end

  @doc "Current counters and configuration for this bridge."
  @spec get_stats(GenServer.server()) :: map()
  def get_stats(server), do: GenServer.call(server, :get_stats)

  @doc "Stop the bridge."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal)

  # ── Server ──

  @impl true
  def init(opts) do
    state = %{
      room_id: Keyword.get(opts, :room_id, "unknown"),
      sink: Keyword.get(opts, :sink),
      knocks: 0,
      presences: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:knock_observed, event}, state) when is_map(event) do
    forward(state.sink, {:neurophone_knock, state.room_id, event})
    {:noreply, %{state | knocks: state.knocks + 1}}
  end

  @impl true
  def handle_cast({:presence_resolved, event}, state) when is_map(event) do
    forward(state.sink, {:neurophone_presence, state.room_id, event})
    {:noreply, %{state | presences: state.presences + 1}}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{room_id: state.room_id, knocks: state.knocks, presences: state.presences}
    {:reply, stats, state}
  end

  # ── Private ──

  defp forward(nil, _msg), do: :ok
  defp forward(sink, msg) when is_pid(sink), do: send(sink, msg)
end
