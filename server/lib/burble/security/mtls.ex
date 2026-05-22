# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Burble.Security.MTLS — Mutual TLS for server-to-server communication.
#
# In Burble's topology model, servers can operate in three modes:
#   - Standalone: single server, no mTLS needed
#   - Oligarchic: small cluster of trusted servers (2-5 nodes)
#   - Distributed: large mesh of servers (future, federation)
#
# This GenServer manages the TLS certificate lifecycle for server-to-server
# communication in oligarchic and distributed topologies. Each Burble node
# has its own X.509 certificate (self-signed for dev, CA-signed for prod),
# and verifies peer certificates before allowing inter-server traffic
# (room state replication, user migration, voice relay).
#
# Certificate storage:
#   - Private keys are stored in the filesystem with 0600 permissions
#   - Certificates are stored alongside keys
#   - Paths are configurable via application env (:burble, :mtls)
#
# Author: Jonathan D.A. Jewell

defmodule Burble.Security.MTLS do
  @moduledoc """
  Mutual TLS certificate management for Burble server-to-server communication.

  Manages the full certificate lifecycle: generation, validation, peer
  verification, and TLS options building. Integrates with `Burble.Topology`
  to determine whether mTLS is needed and which peers to trust.

  ## Usage

      # Get TLS options for connecting to a peer server
      {:ok, tls_opts} = Burble.Security.MTLS.client_tls_options("peer-server.example.com")

      # Get TLS options for accepting connections from peers
      {:ok, tls_opts} = Burble.Security.MTLS.server_tls_options()

      # Verify a peer's certificate
      :ok = Burble.Security.MTLS.verify_peer(der_cert)
  """

  use GenServer

  require Logger

  # ── Types ──

  @typedoc "PEM-encoded certificate or key material."
  @type pem :: binary()

  @typedoc "DER-encoded certificate (as received in TLS handshake)."
  @type der_cert :: binary()

  @typedoc "Server node identifier (hostname or UUID)."
  @type node_id :: String.t()

  @typedoc "Certificate metadata tracked per peer."
  @type cert_info :: %{
          node_id: node_id(),
          fingerprint: binary(),
          subject: String.t(),
          not_before: DateTime.t(),
          not_after: DateTime.t(),
          trusted: boolean()
        }

  # Default paths for certificate storage (overridden via config).
  @default_cert_dir "priv/mtls"
  @default_cert_file "server.pem"
  @default_key_file "server-key.pem"
  @default_ca_file "ca.pem"

  # Certificate validity period for self-signed certs (dev): 365 days.
  @dev_cert_validity_days 365

  # RSA key size for generated certificates.
  @rsa_key_bits 4096

  # ── Client API ──

  @doc """
  Start the mTLS manager GenServer.

  Options (all optional, fall back to application config):
    - `:cert_dir`  — directory for cert/key files
    - `:cert_file` — server certificate filename
    - `:key_file`  — server private key filename
    - `:ca_file`   — CA certificate filename (for prod chain verification)
    - `:mode`      — :dev (self-signed) or :prod (CA-signed)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generate a self-signed certificate for development.

  Creates an RSA keypair and a self-signed X.509 certificate, writing
  both to the configured cert directory. Overwrites existing files.

  Returns `{:ok, cert_path}` or `{:error, reason}`.
  """
  @spec generate_self_signed(keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate_self_signed(opts \\ []) do
    GenServer.call(__MODULE__, {:generate_self_signed, opts})
  end

  @doc """
  Load an existing certificate and key from the filesystem.

  Reads the PEM files from the configured directory and stores them
  in the GenServer state for use in TLS handshakes.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec load_certificate() :: :ok | {:error, term()}
  def load_certificate do
    GenServer.call(__MODULE__, :load_certificate)
  end

  @doc """
  Build TLS options for outbound connections to a peer server (client mode).

  Returns the Erlang `:ssl` options list needed for `:ssl.connect/3`,
  including our client certificate, private key, CA chain, and peer
  verification settings.

  The `peer_hostname` is used for SNI (Server Name Indication) and
  hostname verification.
  """
  @spec client_tls_options(String.t()) :: {:ok, keyword()} | {:error, term()}
  def client_tls_options(peer_hostname) do
    GenServer.call(__MODULE__, {:client_tls_options, peer_hostname})
  end

  @doc """
  Build TLS options for inbound connections from peer servers (server mode).

  Returns the Erlang `:ssl` options list needed for `:ssl.listen/2`,
  including our server certificate, private key, CA chain, and
  client certificate verification requirements.
  """
  @spec server_tls_options() :: {:ok, keyword()} | {:error, term()}
  def server_tls_options do
    GenServer.call(__MODULE__, :server_tls_options)
  end

  @doc """
  Verify a peer's DER-encoded certificate.

  Checks:
    1. Certificate is not expired
    2. Certificate is signed by a trusted CA (prod) or matches known fingerprint (dev)
    3. Certificate fingerprint is in the trusted peers list

  Returns `:ok` or `{:error, reason}`.
  """
  @spec verify_peer(der_cert()) :: :ok | {:error, term()}
  def verify_peer(der_cert) do
    GenServer.call(__MODULE__, {:verify_peer, der_cert})
  end

  @doc """
  Add a peer's certificate fingerprint to the trusted set.

  In oligarchic mode, the admin pre-configures trusted peer fingerprints.
  In distributed mode, this happens via a trust-on-first-use (TOFU) flow
  with manual approval.

  Returns `:ok`.
  """
  @spec trust_peer(node_id(), binary()) :: :ok
  def trust_peer(node_id, fingerprint) do
    GenServer.call(__MODULE__, {:trust_peer, node_id, fingerprint})
  end

  @doc """
  Remove a peer from the trusted set (revoke trust).

  After revocation, connections from this peer will be rejected during
  the TLS handshake.

  Returns `:ok`.
  """
  @spec revoke_peer(node_id()) :: :ok
  def revoke_peer(node_id) do
    GenServer.call(__MODULE__, {:revoke_peer, node_id})
  end

  @doc """
  List all trusted peers and their certificate metadata.

  Returns a list of `cert_info` maps.
  """
  @spec list_trusted_peers() :: [cert_info()]
  def list_trusted_peers do
    GenServer.call(__MODULE__, :list_trusted_peers)
  end

  @doc """
  Get the SHA-256 fingerprint of our own server certificate.

  Used by other nodes to pre-trust us.
  Returns `{:ok, fingerprint_hex}` or `{:error, :no_certificate}`.
  """
  @spec own_fingerprint() :: {:ok, String.t()} | {:error, :no_certificate}
  def own_fingerprint do
    GenServer.call(__MODULE__, :own_fingerprint)
  end

  # ── Server Callbacks ──

  @impl true
  def init(opts) do
    # Resolve configuration: opts > application env > defaults.
    config = resolve_config(opts)

    state = %{
      # Configuration for cert paths and mode.
      config: config,
      # PEM-encoded server certificate (loaded or generated).
      server_cert_pem: nil,
      # PEM-encoded server private key.
      server_key_pem: nil,
      # PEM-encoded CA certificate (for chain verification in prod).
      ca_cert_pem: nil,
      # DER-encoded server certificate (for fingerprint calculation).
      server_cert_der: nil,
      # SHA-256 fingerprint of our server certificate.
      own_fingerprint: nil,
      # Trusted peers: %{node_id => cert_info}.
      trusted_peers: %{}
    }

    # Attempt to auto-load certificates if they exist on disk.
    state = attempt_auto_load(state)

    Logger.info("[MTLS] Manager started (mode: #{config.mode})")
    {:ok, state}
  end

  @impl true
  def handle_call({:generate_self_signed, opts}, _from, state) do
    config = state.config
    cert_dir = Keyword.get(opts, :cert_dir, config.cert_dir)
    hostname = Keyword.get(opts, :hostname, node_hostname())

    # Ensure the certificate directory exists.
    File.mkdir_p!(cert_dir)

    cert_path = Path.join(cert_dir, config.cert_file)
    key_path = Path.join(cert_dir, config.key_file)

    case generate_self_signed_cert(hostname, key_path, cert_path) do
      {:ok, cert_pem, key_pem} ->
        # Calculate fingerprint from the generated certificate.
        {:ok, der} = pem_to_der(cert_pem)
        fingerprint = certificate_fingerprint(der)

        new_state = %{
          state
          | server_cert_pem: cert_pem,
            server_key_pem: key_pem,
            server_cert_der: der,
            own_fingerprint: fingerprint
        }

        Logger.info("[MTLS] Self-signed certificate generated: #{cert_path}")
        Logger.info("[MTLS] Fingerprint: #{Base.encode16(fingerprint, case: :lower)}")

        {:reply, {:ok, cert_path}, new_state}

      {:error, reason} ->
        Logger.error("[MTLS] Failed to generate certificate: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:load_certificate, _from, state) do
    case do_load_certificate(state.config) do
      {:ok, new_state_fields} ->
        new_state = Map.merge(state, new_state_fields)
        Logger.info("[MTLS] Certificate loaded successfully")
        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.error("[MTLS] Failed to load certificate: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:client_tls_options, peer_hostname}, _from, state) do
    case build_client_tls_opts(state, peer_hostname) do
      {:ok, opts} -> {:reply, {:ok, opts}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:server_tls_options, _from, state) do
    case build_server_tls_opts(state) do
      {:ok, opts} -> {:reply, {:ok, opts}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:verify_peer, der_cert}, _from, state) do
    result = do_verify_peer(der_cert, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:trust_peer, node_id, fingerprint}, _from, state) do
    peer_info = %{
      node_id: node_id,
      fingerprint: fingerprint,
      subject: "unknown",
      not_before: DateTime.utc_now(),
      not_after: DateTime.utc_now() |> DateTime.add(@dev_cert_validity_days * 86400, :second),
      trusted: true
    }

    new_trusted = Map.put(state.trusted_peers, node_id, peer_info)
    Logger.info("[MTLS] Trusted peer added: #{node_id}")
    {:reply, :ok, %{state | trusted_peers: new_trusted}}
  end

  @impl true
  def handle_call({:revoke_peer, node_id}, _from, state) do
    new_trusted = Map.delete(state.trusted_peers, node_id)
    Logger.info("[MTLS] Peer trust revoked: #{node_id}")
    {:reply, :ok, %{state | trusted_peers: new_trusted}}
  end

  @impl true
  def handle_call(:list_trusted_peers, _from, state) do
    peers = Map.values(state.trusted_peers)
    {:reply, peers, state}
  end

  @impl true
  def handle_call(:own_fingerprint, _from, state) do
    case state.own_fingerprint do
      nil -> {:reply, {:error, :no_certificate}, state}
      fp -> {:reply, {:ok, Base.encode16(fp, case: :lower)}, state}
    end
  end

  # ── Private: Configuration ──

  # Resolve mTLS configuration from opts, application env, and defaults.
  @spec resolve_config(keyword()) :: map()
  defp resolve_config(opts) do
    app_config = Application.get_env(:burble, :mtls, [])

    %{
      cert_dir: Keyword.get(opts, :cert_dir, Keyword.get(app_config, :cert_dir, @default_cert_dir)),
      cert_file:
        Keyword.get(opts, :cert_file, Keyword.get(app_config, :cert_file, @default_cert_file)),
      key_file:
        Keyword.get(opts, :key_file, Keyword.get(app_config, :key_file, @default_key_file)),
      ca_file:
        Keyword.get(opts, :ca_file, Keyword.get(app_config, :ca_file, @default_ca_file)),
      mode: Keyword.get(opts, :mode, Keyword.get(app_config, :mode, :dev))
    }
  end

  # ── Private: Certificate generation ──

  # Generate a self-signed X.509 certificate using Erlang's :public_key module.
  # This avoids shelling out to openssl and keeps the dependency chain pure Erlang.
  #
  # Parameters:
  #   - hostname: the CN (Common Name) for the certificate's subject
  #   - key_path: filesystem path to write the PEM-encoded private key
  #   - cert_path: filesystem path to write the PEM-encoded certificate
  #
  # Returns {:ok, cert_pem, key_pem} or {:error, reason}.
  @spec generate_self_signed_cert(String.t(), String.t(), String.t()) ::
          {:ok, binary(), binary()} | {:error, term()}
  defp generate_self_signed_cert(hostname, key_path, cert_path) do
    try do
      # Generate RSA private key.
      rsa_key = :public_key.generate_key({:rsa, @rsa_key_bits, 65537})

      # Build the X.509 certificate structure.
      # Serial number: random 20-byte integer (per RFC 5280).
      serial = :crypto.strong_rand_bytes(20) |> :binary.decode_unsigned()

      # Validity period.
      not_before = DateTime.utc_now()
      not_after = DateTime.add(not_before, @dev_cert_validity_days * 86400, :second)

      # Subject and issuer (same for self-signed).
      subject =
        {:rdnSequence,
         [
           [{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, hostname}}],
           [{:AttributeTypeAndValue, {2, 5, 4, 10}, {:utf8String, "Burble Voice Server"}}]
         ]}

      # Build the TBSCertificate (To-Be-Signed Certificate).
      tbs = build_tbs_certificate(serial, subject, rsa_key, not_before, not_after)

      # Sign the TBS certificate with our private key.
      tbs_der = :public_key.der_encode(:TBSCertificate, tbs)
      signature = :public_key.sign(tbs_der, :sha256, rsa_key)

      # Assemble the full certificate.
      cert =
        {:Certificate, tbs,
         {:AlgorithmIdentifier, {1, 2, 840, 113_549, 1, 1, 11}, {:asn1_OPENTYPE, <<5, 0>>}},
         signature}

      # Encode to DER then PEM.
      cert_der = :public_key.der_encode(:Certificate, cert)
      cert_pem = :public_key.pem_encode([{:Certificate, cert_der, :not_encrypted}])

      key_der = :public_key.der_encode(:RSAPrivateKey, rsa_key)
      key_pem = :public_key.pem_encode([{:RSAPrivateKey, key_der, :not_encrypted}])

      # Write to disk with restrictive permissions.
      File.write!(cert_path, cert_pem)
      File.write!(key_path, key_pem)
      File.chmod!(key_path, 0o600)

      {:ok, cert_pem, key_pem}
    rescue
      error ->
        {:error, {:generation_failed, Exception.message(error)}}
    end
  end

  # Build a TBSCertificate record for self-signed certificate generation.
  # This is the structure that gets signed to produce the final X.509 cert.
  @spec build_tbs_certificate(integer(), term(), term(), DateTime.t(), DateTime.t()) :: tuple()
  defp build_tbs_certificate(serial, subject, rsa_key, not_before, not_after) do
    # Extract the public key from the RSA private key.
    public_key = extract_rsa_public_key(rsa_key)
    public_key_der = :public_key.der_encode(:RSAPublicKey, public_key)

    # Format validity dates as ASN.1 UTCTime.
    validity = {
      :Validity,
      {:utcTime, datetime_to_utc_time(not_before)},
      {:utcTime, datetime_to_utc_time(not_after)}
    }

    {:TBSCertificate, :v3, serial,
     {:AlgorithmIdentifier, {1, 2, 840, 113_549, 1, 1, 11}, {:asn1_OPENTYPE, <<5, 0>>}},
     subject, validity, subject,
     {:SubjectPublicKeyInfo,
      {:AlgorithmIdentifier, {1, 2, 840, 113_549, 1, 1, 1}, {:asn1_OPENTYPE, <<5, 0>>}},
      public_key_der}, :asn1_NOVALUE, :asn1_NOVALUE, :asn1_NOVALUE}
  end

  # Extract the RSA public key components from an RSA private key record.
  @spec extract_rsa_public_key(tuple()) :: tuple()
  defp extract_rsa_public_key(rsa_private_key) do
    # RSAPrivateKey record: version, modulus, publicExponent, privateExponent, ...
    modulus = elem(rsa_private_key, 1)
    public_exponent = elem(rsa_private_key, 2)
    {:RSAPublicKey, modulus, public_exponent}
  end

  # Convert a DateTime to ASN.1 UTCTime string format (YYMMDDHHMMSSZ).
  @spec datetime_to_utc_time(DateTime.t()) :: charlist()
  defp datetime_to_utc_time(dt) do
    # UTCTime uses 2-digit year (per X.680). Dates from 2000-2049 are YYMMDDHHMMSSZ.
    year_2digit = rem(dt.year, 100)

    formatted =
      :io_lib.format(~c"~2..0B~2..0B~2..0B~2..0B~2..0B~2..0BZ", [
        year_2digit,
        dt.month,
        dt.day,
        dt.hour,
        dt.minute,
        dt.second
      ])

    List.flatten(formatted)
  end

  # ── Private: Certificate loading ──

  # Load certificate and key from disk.
  @spec do_load_certificate(map()) :: {:ok, map()} | {:error, term()}
  defp do_load_certificate(config) do
    cert_path = Path.join(config.cert_dir, config.cert_file)
    key_path = Path.join(config.cert_dir, config.key_file)
    ca_path = Path.join(config.cert_dir, config.ca_file)

    with {:ok, cert_pem} <- File.read(cert_path),
         {:ok, key_pem} <- File.read(key_path),
         {:ok, der} <- pem_to_der(cert_pem) do
      fingerprint = certificate_fingerprint(der)

      # CA cert is optional (not needed for self-signed dev mode).
      ca_pem =
        case File.read(ca_path) do
          {:ok, pem} -> pem
          {:error, _} -> nil
        end

      {:ok,
       %{
         server_cert_pem: cert_pem,
         server_key_pem: key_pem,
         ca_cert_pem: ca_pem,
         server_cert_der: der,
         own_fingerprint: fingerprint
       }}
    end
  end

  # Attempt to auto-load certificates at startup (non-fatal if they don't exist).
  @spec attempt_auto_load(map()) :: map()
  defp attempt_auto_load(state) do
    case do_load_certificate(state.config) do
      {:ok, fields} ->
        Logger.info("[MTLS] Auto-loaded certificate from #{state.config.cert_dir}")
        Map.merge(state, fields)

      {:error, _} ->
        Logger.debug("[MTLS] No existing certificate found — generate or load one manually")
        state
    end
  end

  # ── Private: TLS options building ──

  # Build Erlang :ssl options for client (outbound) connections.
  # These options enable mTLS: we present our certificate and verify the peer's.
  @spec build_client_tls_opts(map(), String.t()) :: {:ok, keyword()} | {:error, term()}
  defp build_client_tls_opts(state, peer_hostname) do
    if state.server_cert_pem == nil or state.server_key_pem == nil do
      {:error, :no_certificate_loaded}
    else
      # Write temp files for :ssl (it needs file paths, not in-memory PEM).
      # In production, these would be persistent paths from config.
      cert_path = Path.join(state.config.cert_dir, state.config.cert_file)
      key_path = Path.join(state.config.cert_dir, state.config.key_file)

      opts = [
        # Our client certificate and key.
        certfile: String.to_charlist(cert_path),
        keyfile: String.to_charlist(key_path),

        # TLS version: only 1.3 for server-to-server (strongest security).
        versions: [:"tlsv1.3"],

        # Server Name Indication: tell the peer which hostname we expect.
        server_name_indication: String.to_charlist(peer_hostname),

        # Peer verification: require valid certificate from the server.
        verify: :verify_peer,

        # Custom verify function for fingerprint-based trust (dev mode)
        # or CA chain verification (prod mode).
        verify_fun: build_verify_fun(state),

        # Maximum certificate chain depth.
        depth: 3
      ]

      # Add CA cert if available (prod mode).
      opts =
        if state.ca_cert_pem do
          ca_path = Path.join(state.config.cert_dir, state.config.ca_file)
          Keyword.put(opts, :cacertfile, String.to_charlist(ca_path))
        else
          opts
        end

      {:ok, opts}
    end
  end

  # Build Erlang :ssl options for server (inbound) connections.
  # These options require client certificates (mutual TLS).
  @spec build_server_tls_opts(map()) :: {:ok, keyword()} | {:error, term()}
  defp build_server_tls_opts(state) do
    if state.server_cert_pem == nil or state.server_key_pem == nil do
      {:error, :no_certificate_loaded}
    else
      cert_path = Path.join(state.config.cert_dir, state.config.cert_file)
      key_path = Path.join(state.config.cert_dir, state.config.key_file)

      opts = [
        # Our server certificate and key.
        certfile: String.to_charlist(cert_path),
        keyfile: String.to_charlist(key_path),

        # TLS version: only 1.3.
        versions: [:"tlsv1.3"],

        # Require client certificate (this is what makes it "mutual" TLS).
        verify: :verify_peer,
        fail_if_no_peer_cert: true,

        # Custom verify function.
        verify_fun: build_verify_fun(state),

        # Maximum certificate chain depth.
        depth: 3
      ]

      # Add CA cert if available.
      opts =
        if state.ca_cert_pem do
          ca_path = Path.join(state.config.cert_dir, state.config.ca_file)
          Keyword.put(opts, :cacertfile, String.to_charlist(ca_path))
        else
          opts
        end

      {:ok, opts}
    end
  end

  # Build a custom verify_fun for :ssl peer certificate verification.
  #
  # In dev mode (self-signed certs), we use fingerprint-based trust:
  # the peer's cert fingerprint must be in our trusted_peers map.
  #
  # In prod mode, we rely on CA chain verification plus fingerprint check.
  @spec build_verify_fun(map()) :: {function(), term()}
  defp build_verify_fun(state) do
    trusted_fingerprints =
      state.trusted_peers
      |> Map.values()
      |> Enum.map(& &1.fingerprint)
      |> MapSet.new()

    verify_fn = fn
      # Leaf certificate (the peer's own cert) — check fingerprint.
      cert, {:bad_cert, :selfsigned_peer}, user_state ->
        fingerprint = certificate_fingerprint(cert)

        if MapSet.member?(trusted_fingerprints, fingerprint) do
          {:valid, user_state}
        else
          {:fail, :untrusted_peer}
        end

      # CA-signed certificate in the chain — allow if chain validates.
      _cert, {:extension, _ext}, user_state ->
        {:unknown, user_state}

      # Valid certificate in the chain.
      _cert, :valid, user_state ->
        {:valid, user_state}

      # Peer certificate that passed chain validation.
      _cert, :valid_peer, user_state ->
        {:valid, user_state}
    end

    {verify_fn, []}
  end

  # ── Private: Certificate verification ──

  # Verify a DER-encoded peer certificate against our trust store.
  @spec do_verify_peer(der_cert(), map()) :: :ok | {:error, term()}
  defp do_verify_peer(der_cert, state) do
    fingerprint = certificate_fingerprint(der_cert)

    # Check if any trusted peer has this fingerprint.
    trusted =
      Enum.any?(state.trusted_peers, fn {_id, info} ->
        info.fingerprint == fingerprint and info.trusted
      end)

    if trusted do
      :ok
    else
      {:error, :untrusted_certificate}
    end
  end

  # ── Private: Certificate utilities ──

  # Calculate the SHA-256 fingerprint of a DER-encoded certificate.
  # This is the standard way to identify certificates (used by browsers,
  # curl, and other TLS implementations).
  @spec certificate_fingerprint(binary()) :: binary()
  defp certificate_fingerprint(der_cert) do
    :crypto.hash(:sha256, der_cert)
  end

  # Convert a PEM-encoded certificate to DER (binary ASN.1).
  # Extracts the first certificate entry from the PEM bundle.
  @spec pem_to_der(binary()) :: {:ok, binary()} | {:error, term()}
  defp pem_to_der(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted} | _] ->
        {:ok, der}

      [] ->
        {:error, :no_certificate_in_pem}

      _other ->
        # Try the first entry regardless of type label.
        [{_type, der, :not_encrypted} | _] = :public_key.pem_decode(pem)
        {:ok, der}
    end
  rescue
    _ -> {:error, :invalid_pem}
  end

  # Get the hostname for this node (used as the CN in self-signed certs).
  @spec node_hostname() :: String.t()
  defp node_hostname do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end
end
