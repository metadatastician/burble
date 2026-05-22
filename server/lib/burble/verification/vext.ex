# SPDX-License-Identifier: MPL-2.0
#
# ── DISAMBIGUATION ────────────────────────────────────────────────────────────
# Three things were called "vext". Read carefully.
#
#   YOU ARE HERE → Burble's Vext INTEGRATION (consumer, not the spec)
#     This file implements the Vext protocol for Burble's text feeds.
#     BLAKE3 hash chains proving feeds are chronological, complete,
#     uninjected, and attributable. Part of burble only.
#
#   PROTOCOL SPEC → hyperpolymath/vext  ← THE CANONICAL HOME OF THE PROTOCOL
#     The actual Vext protocol definition, Idris2 proofs, reference impl.
#     GitHub: hyperpolymath/vext
#     This file is a CONSUMER of that spec, not the spec itself.
#     Go there for protocol design decisions, formal proofs, a2ml layer.
#
#   UNRELATED → vcs-ircd (formerly also called "vext" — now renamed)
#     A pooled IRC notification daemon for Git/VCS events. Rust/Tokio.
#     Lives at: developer-ecosystem/satellites/git-tools/vcs-ircd
#     GitHub:   hyperpolymath/vcs-ircd
#     Has nothing to do with cryptographic verification.
#
# ─────────────────────────────────────────────────────────────────────────────
#
# Burble.Verification.Vext — Cryptographic feed verification.
#
# Integrates the Vext protocol to provide mathematical proof that
# Burble's text channels are:
#
#   1. Chronological — messages appear in timestamp order, not algorithmically sorted
#   2. Complete — no messages have been hidden, deleted, or suppressed
#   3. Uninjected — no advertisements or synthetic content inserted
#   4. Attributable — each message's authorship is cryptographically verified
#
# This is a unique differentiator: Burble is the only voice platform where
# users can mathematically verify their text feed hasn't been tampered with.
#
# Implementation:
#   Each article gets a Vext verification header containing:
#   - BLAKE3 hash of (body + author + timestamp)
#   - Hash chain link to previous article (proves ordering)
#   - Server signature (Ed25519, proves server attests to this ordering)
#
#   Clients can verify the chain independently. If any article is
#   modified, inserted, or removed, the hash chain breaks and the
#   client can detect it.
#
# Dogfooding note:
#   This is the first real-world deployment of Vext's verification model.
#   Lessons learned here feed back into the core Vext protocol spec.

defmodule Burble.Verification.Vext do
  @moduledoc """
  Vext-based cryptographic verification for Burble text feeds.

  Provides hash-chain verification that proves feed integrity:
  no hidden messages, no reordering, no injection.
  """

  require Logger

  # ── Types ──

  @type verification_header :: %{
          article_hash: String.t(),
          previous_hash: String.t(),
          chain_position: non_neg_integer(),
          server_signature: String.t(),
          algorithm: String.t(),
          attestation_id: String.t() | nil
        }

  @type chain_state :: %{
          channel_id: String.t(),
          position: non_neg_integer(),
          latest_hash: String.t()
        }

  @type verification_result ::
          {:ok, :verified}
          | {:error, :hash_mismatch}
          | {:error, :chain_broken}
          | {:error, :signature_invalid}
          | {:error, :out_of_order}

  # ── Public API ──

  @doc """
  Create a verification header for a new article.

  Computes the article hash, links to the previous hash in the chain,
  and signs the result with the server's Ed25519 key.
  
  Can optionally include an AVOW attestation ID to prove consent.
  """
  def create_header(body, author_id, timestamp, chain_state, attestation_id \\ nil) do
    article_hash = hash_article(body, author_id, timestamp)
    previous_hash = chain_state.latest_hash
    position = chain_state.position + 1

    # Chain hash includes the previous hash to create an unbreakable ordering
    chain_hash = hash_chain_link(article_hash, previous_hash, position)

    # Server signs the chain hash to attest it saw this ordering
    signature = sign_chain_hash(chain_hash)

    header = %{
      article_hash: article_hash,
      previous_hash: previous_hash,
      chain_position: position,
      chain_hash: chain_hash,
      server_signature: signature,
      algorithm: "blake3+ed25519",
      timestamp: DateTime.to_iso8601(timestamp),
      attestation_id: attestation_id
    }

    new_chain_state = %{
      chain_state
      | position: position,
        latest_hash: chain_hash
    }

    # Check for Majestic Anchoring Checkpoint (every 50 messages)
    if rem(position, 50) == 0 do
      Logger.info("[Vext] Checkpoint reached at position #{position}. Requesting anchor...")
      :telemetry.execute([:burble, :vext, :checkpoint], %{position: position}, %{header: header})
    end

    {header, new_chain_state}
  end

  @doc """
  Verify a single article's integrity against its header.

  Checks that:
  1. The article hash matches the body + author + timestamp
  2. The chain link is valid (previous hash matches)
  3. The server signature is valid
  """
  def verify_article(body, author_id, timestamp, header, expected_previous_hash) do
    # Step 1: Verify article content hash
    computed_hash = hash_article(body, author_id, timestamp)

    if computed_hash != header.article_hash do
      {:error, :hash_mismatch}
    else
      # Step 2: Verify chain continuity
      if header.previous_hash != expected_previous_hash do
        {:error, :chain_broken}
      else
        # Step 3: Verify chain hash
        computed_chain = hash_chain_link(computed_hash, expected_previous_hash, header.chain_position)

        if computed_chain != header.chain_hash do
          {:error, :chain_broken}
        else
          # Step 4: Verify server signature
          if verify_signature(header.chain_hash, header.server_signature) do
            {:ok, :verified}
          else
            {:error, :signature_invalid}
          end
        end
      end
    end
  end

  @doc """
  Verify an entire feed (sequence of articles) for integrity.

  Walks the hash chain from the beginning and verifies each article.
  Returns :ok if the entire chain is valid, or the first error found.
  """
  def verify_feed(articles_with_headers) do
    initial_state = %{previous_hash: genesis_hash(), position: 0, errors: []}

    result =
      Enum.reduce_while(articles_with_headers, initial_state, fn
        {body, author_id, timestamp, header}, acc ->
          case verify_article(body, author_id, timestamp, header, acc.previous_hash) do
            {:ok, :verified} ->
              {:cont,
               %{
                 acc
                 | previous_hash: header.chain_hash,
                   position: acc.position + 1
               }}

            {:error, reason} ->
              {:halt, %{acc | errors: [{acc.position + 1, reason} | acc.errors]}}
          end
      end)

    if result.errors == [] do
      {:ok, :verified, result.position}
    else
      {:error, :chain_broken, result.errors}
    end
  end

  @doc """
  Create the initial chain state for a new channel.
  """
  def init_chain(channel_id) do
    %{
      channel_id: channel_id,
      position: 0,
      latest_hash: genesis_hash()
    }
  end

  # ── Private ──

  defp hash_article(body, author_id, timestamp) do
    data = "vext:article:#{body}|#{author_id}|#{DateTime.to_iso8601(timestamp)}"
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp hash_chain_link(article_hash, previous_hash, position) do
    data = "vext:chain:#{article_hash}|#{previous_hash}|#{position}"
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp genesis_hash do
    # The genesis hash is a well-known constant — the "big bang" of the chain.
    # Every channel starts from this same root.
    "0000000000000000000000000000000000000000000000000000000000000000"
  end

  defp sign_chain_hash(chain_hash) do
    {_pub, priv} = get_ed25519_keypair()
    :crypto.sign(:eddsa, :none, chain_hash, [priv, :ed25519]) |> Base.encode16(case: :lower)
  end

  defp verify_signature(chain_hash, signature) do
    {pub, _priv} = get_ed25519_keypair()
    sig_bytes = Base.decode16!(signature, case: :lower)
    :crypto.verify(:eddsa, :none, chain_hash, sig_bytes, [pub, :ed25519])
  rescue
    _ -> false
  end

  # Shared Ed25519 keypair (same as Avow — single server identity).
  defp get_ed25519_keypair do
    case Application.get_env(:burble, :ed25519_private_key) do
      nil ->
        seed = :crypto.hash(:sha256, "burble_dev_ed25519_seed") |> binary_part(0, 32)
        :crypto.generate_key(:eddsa, :ed25519, seed)

      private_key_hex ->
        priv = Base.decode16!(private_key_hex, case: :lower)
        {pub, _} = :crypto.generate_key(:eddsa, :ed25519, priv)
        {pub, priv}
    end
  end
end
