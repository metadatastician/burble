# SPDX-License-Identifier: MPL-2.0
#
# Burble.Topology — Deployment topology configuration.
#
# Burble supports four deployment topologies:
#
#   1. Monarchic  — Single server owns everything. Default for self-hosting.
#   2. Oligarchic — Trusted server cluster. Distributed Erlang + VeriSimDB federation.
#   3. Distributed — Federated independent servers. Vext integrity chains.
#   4. Serverless  — Pure peer-to-peer. E2EE mandatory, STUN/TURN only.
#
# Each topology activates/deactivates specific subsystems. The topology
# is set at boot time via config and cannot be changed at runtime.
#
# Trustfile compatibility:
#   - Monarchic:    server is fully trusted (all operations local)
#   - Oligarchic:   cluster peers are trusted (mTLS + shared secret)
#   - Distributed:  servers are semi-trusted (Vext proves data integrity)
#   - Serverless:   server is untrusted (E2EE, no server-side anything)

defmodule Burble.Topology do
  @moduledoc """
  Deployment topology for Burble.

  Configures which subsystems are active based on the deployment mode.
  Set in config:

      config :burble, Burble.Topology,
        mode: :monarchic  # or :oligarchic, :distributed, :serverless

  ## Topology modes

  ### Monarchic (default)
  Single server owns all state. Simplest deployment — one Elixir node,
  one VeriSimDB instance. All features available. Server is fully trusted.

  ### Oligarchic
  Cluster of 2+ trusted servers sharing state via distributed Erlang
  (PubSub, process registry) and VeriSimDB federation. Rooms can span
  nodes. Servers trust each other (mTLS authentication).

  ### Distributed (federated)
  Independent servers with no shared trust. Users on server A can join
  rooms on server B via federation protocol. Vext hash chains provide
  cross-server message integrity. Avow attestations prove consent
  across server boundaries.

  ### Serverless (P2P)
  No persistent server — only STUN/TURN for connection bootstrapping.
  E2EE is mandatory. Room state is maintained client-side via CRDTs.
  No server-side recording, no server-side moderation. Users exchange
  signaling via a thin relay that sees only encrypted metadata.

  ## Feature matrix

  | Feature              | Monarchic | Oligarchic | Distributed | Serverless |
  |----------------------|-----------|------------|-------------|------------|
  | VeriSimDB store      | yes       | federated  | federated   | no         |
  | Server-side recording| yes       | yes        | per-server  | no         |
  | Permissions          | yes       | yes        | per-server  | client-only|
  | Avow attestations    | yes       | yes        | yes         | yes (local)|
  | Vext integrity       | yes       | yes        | required    | yes (local)|
  | E2EE                 | optional  | optional   | recommended | mandatory  |
  | Privacy mode default | turn_only | turn_only  | e2ee        | maximum    |
  | Moderation           | full      | full       | per-server  | none       |
  | Audit logging        | yes       | yes        | per-server  | no         |
  | User accounts        | yes       | shared     | per-server  | anonymous  |
  """

  @type topology_mode :: :monarchic | :oligarchic | :distributed | :serverless

  @doc "Get the current deployment topology mode."
  @spec mode() :: topology_mode()
  def mode do
    config = Application.get_env(:burble, __MODULE__, [])
    Keyword.get(config, :mode, :monarchic)
  end

  @doc "Whether VeriSimDB persistent storage is available in this topology."
  @spec has_store?() :: boolean()
  def has_store? do
    mode() in [:monarchic, :oligarchic, :distributed]
  end

  @doc "Whether server-side recording is available."
  @spec has_recording?() :: boolean()
  def has_recording? do
    mode() in [:monarchic, :oligarchic, :distributed]
  end

  @doc "Whether server-side moderation is available."
  @spec has_moderation?() :: boolean()
  def has_moderation? do
    mode() in [:monarchic, :oligarchic, :distributed]
  end

  @doc "Whether E2EE is mandatory in this topology."
  @spec e2ee_mandatory?() :: boolean()
  def e2ee_mandatory? do
    mode() == :serverless
  end

  @doc "Default privacy mode for this topology."
  @spec default_privacy() :: Burble.Media.Engine.privacy_mode()
  def default_privacy do
    case mode() do
      :monarchic -> :turn_only
      :oligarchic -> :turn_only
      :distributed -> :e2ee
      :serverless -> :maximum
    end
  end

  @doc "Whether federation protocol is active."
  @spec federated?() :: boolean()
  def federated? do
    mode() in [:oligarchic, :distributed]
  end

  @doc "Whether user accounts are persisted (vs anonymous-only)."
  @spec has_accounts?() :: boolean()
  def has_accounts? do
    mode() != :serverless
  end

  @doc "Whether audit logging is active."
  @spec has_audit?() :: boolean()
  def has_audit? do
    mode() in [:monarchic, :oligarchic, :distributed]
  end

  @doc """
  Get the full capability map for the current topology.

  Useful for client-side feature detection — the client can query this
  to know what features are available on this server.
  """
  @spec capabilities() :: map()
  def capabilities do
    %{
      topology: mode(),
      store: has_store?(),
      recording: has_recording?(),
      moderation: has_moderation?(),
      e2ee_mandatory: e2ee_mandatory?(),
      default_privacy: default_privacy(),
      federated: federated?(),
      accounts: has_accounts?(),
      audit: has_audit?()
    }
  end
end
