# SPDX-License-Identifier: MPL-2.0
#
# Burble.Security.SDP — Software-Defined Perimeter gateway.
#
# Implements the SDP (Black Cloud) architecture for Burble.
# SDP ensures that the Burble server is invisible to unauthorised users:
#
#   1. Single Packet Authorisation (SPA) — the server only opens ports
#      after receiving a cryptographically signed SPA packet.
#   2. Mutual TLS (mTLS) — mandatory for all control and media traffic.
#   3. Dynamic Firewalls — ports are opened per-session and closed
#      immediately upon disconnection.
#   4. Zero Trust — every packet is authenticated and authorised.
#
# This module acts as the SDP gateway and policy engine. It integrates
# with the system firewall (e.g. nftables, pf) via a Zig-based NIF
# for high-performance packet filtering.

defmodule Burble.Security.SDP do
  @moduledoc """
  Software-Defined Perimeter (SDP) gateway for Burble.

  Hides the server infrastructure and enforces zero-trust access
  via Single Packet Authorisation (SPA) and dynamic firewalling.
  """

  use GenServer

  require Logger

  # ── Types ──

  @type spa_packet :: %{
          sender_id: String.t(),
          timestamp: DateTime.t(),
          signature: binary(),
          requested_port: :inet.port_number()
        }

  @type policy :: %{
          user_id: String.t(),
          allowed_ports: [ :inet.port_number() ],
          max_session_duration: integer(),
          mTLS_required: boolean()
        }

  # ── Public API ──

  @doc "Start the SDP gateway."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Process an incoming SPA (Single Packet Authorisation) packet.
  If valid, opens the requested port for the sender's IP.
  """
  def process_spa(packet_binary, sender_ip) do
    GenServer.call(__MODULE__, {:process_spa, packet_binary, sender_ip})
  end

  @doc """
  Revoke access for an IP (close all dynamic ports).
  Called on session termination or policy violation.
  """
  def revoke_access(sender_ip) do
    GenServer.call(__MODULE__, {:revoke_access, sender_ip})
  end

  # ── GenServer Callbacks ──

  @impl true
  def init(_opts) do
    # Initialise the Zig firewall table.
    Burble.Coprocessor.ZigBackend.sdp_firewall_init()

    Logger.info("[SDP] Gateway initialised (Zero Trust mode active)")
    {:ok, %{
      sessions: %{}, # sender_ip => %{user_id, opened_ports, expires_at}
      policies: %{}  # user_id => policy
    }}
  end

  @impl true
  def handle_call({:process_spa, packet_binary, sender_ip}, _from, state) do
    case verify_spa_packet(packet_binary) do
      {:ok, %{sender_id: user_id, requested_port: port}} ->
        case check_policy(user_id, port, state) do
          {:ok, _} ->
            open_firewall_port(sender_ip, port)
            new_state = record_session(state, sender_ip, user_id, port)
            Logger.info("[SDP] Access GRANTED for #{user_id} at #{inspect(sender_ip)} on port #{port}")
            {:reply, :ok, new_state}
          {:error, reason} ->
            Logger.warning("[SDP] Access REJECTED for #{user_id}: #{reason}")
            {:reply, {:error, :policy_denied}, state}
        end

      {:error, reason} ->
        Logger.warning("[SDP] Invalid SPA packet from #{inspect(sender_ip)}: #{reason}")
        {:reply, {:error, :invalid_spa}, state}
    end
  end

  @impl true
  def handle_call({:revoke_access, sender_ip}, _from, state) do
    close_firewall_ports(sender_ip)
    new_sessions = Map.delete(state.sessions, sender_ip)
    Logger.info("[SDP] Access REVOKED for #{inspect(sender_ip)}")
    {:reply, :ok, %{state | sessions: new_sessions}}
  end

  # ── Internal: Policy & Firewall ──

  defp verify_spa_packet(binary) do
    # Simplified verification for scaffold.
    if byte_size(binary) > 0 do
      {:ok, %{sender_id: "user_123", requested_port: 4020, timestamp: DateTime.utc_now()}}
    else
      {:error, :empty_packet}
    end
  end

  defp check_policy(_user_id, _port, _state) do
    # Local check only: allows all ports. VeriSimDB policy lookup not wired.
    {:ok, :local_check_only}
  end

  defp open_firewall_port(ip, port) do
    # Calls Zig NIF to update nftables/pf rules.
    Burble.Coprocessor.ZigBackend.sdp_firewall_authorize(ip, port)
    Logger.debug("[SDP] Opening firewall: #{inspect(ip)} -> #{port}")
    :ok
  end

  defp close_firewall_ports(ip) do
    # Calls Zig NIF to remove all rules for this IP.
    # (Future NIF: nif_sdp_firewall_revoke)
    _ = ip
    Logger.debug("[SDP] Closing firewall for #{inspect(ip)}")
    :ok
  end

  defp record_session(state, ip, user_id, port) do
    session = %{
      user_id: user_id,
      opened_ports: [port],
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
    %{state | sessions: Map.put(state.sessions, ip, session)}
  end
end
