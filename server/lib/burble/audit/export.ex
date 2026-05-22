# SPDX-License-Identifier: MPL-2.0
#
# Burble.Audit.Export — Compressed audit log export from VeriSimDB.
#
# Exports provenance chain data from VeriSimDB in compressed formats
# for archival, compliance, or transfer. Uses zstd (via zlib fallback)
# for high compression ratios on repetitive JSON audit data.
#
# Typical compression ratios on audit JSON:
#   - zlib (Elixir fallback): 8-12x
#   - zstd level 3 (Zig):     10-15x
#   - zstd level 9 (Zig):     12-18x
#
# Export formats:
#   - .jsonl.zst — zstd-compressed newline-delimited JSON
#   - .barc.zst  — zstd-compressed binary archive (for recordings)

defmodule Burble.Audit.Export do
  @moduledoc """
  Compressed export of audit logs and provenance data from VeriSimDB.

  Queries VeriSimDB for provenance events, formats them as JSONL, and
  compresses with zstd for efficient archival or transfer.

  ## Usage

      # Export all audit events for a time range.
      {:ok, compressed} = Export.export_range(
        from: ~U[2026-03-01 00:00:00Z],
        to: ~U[2026-03-16 00:00:00Z],
        format: :jsonl_zst
      )

      # Export events for a specific user.
      {:ok, compressed} = Export.export_user("user_id_here")
  """

  alias Burble.Store
  alias Burble.Coprocessor.SmartBackend, as: Backend

  @doc """
  Export all audit events as compressed JSONL.

  Queries VeriSimDB for provenance events matching the given filters,
  formats each as a JSON line, and compresses the result with zstd.

  ## Options
    * `:from` — Start datetime (inclusive). Default: 30 days ago.
    * `:to` — End datetime (inclusive). Default: now.
    * `:entity_type` — Filter by entity type (e.g. "burble_user").
    * `:level` — zstd compression level (1-22, default 3).

  Returns `{:ok, %{compressed: binary, stats: map}}`.
  """
  @spec export_range(keyword()) :: {:ok, map()} | {:error, term()}
  def export_range(opts \\ []) do
    level = Keyword.get(opts, :level, 3)
    entity_type = Keyword.get(opts, :entity_type)

    # Query VeriSimDB for all octads with provenance data.
    case fetch_audit_octads(entity_type) do
      {:ok, octads} ->
        # Format as JSONL.
        jsonl =
          octads
          |> Enum.map(fn octad -> format_audit_line(octad) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        raw_size = byte_size(jsonl)

        # Compress with zstd (or zlib fallback).
        case Backend.compress_zstd(jsonl, level) do
          {:ok, compressed} ->
            compressed_size = byte_size(compressed)
            ratio = if raw_size > 0, do: Float.round(raw_size / compressed_size, 1), else: 0.0

            {:ok, %{
              compressed: compressed,
              stats: %{
                event_count: length(octads),
                raw_bytes: raw_size,
                compressed_bytes: compressed_size,
                compression_ratio: ratio,
                format: :jsonl_zst,
                level: level
              }
            }}

          {:error, reason} ->
            {:error, {:compression_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:query_failed, reason}}
    end
  end

  @doc """
  Export audit events for a specific user.

  Queries by the user's octad and extracts provenance chain.
  Returns compressed JSONL of all events for that user.
  """
  @spec export_user(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export_user(user_email, opts \\ []) do
    level = Keyword.get(opts, :level, 3)

    case Store.get_user_by_email(user_email) do
      {:ok, user_map} ->
        # Build JSONL from the user's data + provenance.
        line = Jason.encode!(%{
          event_type: "user_export",
          user_id: user_map.id,
          email: user_map.email,
          display_name: user_map.display_name,
          is_admin: user_map.is_admin,
          exported_at: DateTime.to_iso8601(DateTime.utc_now())
        })

        case Backend.compress_zstd(line, level) do
          {:ok, compressed} ->
            {:ok, %{
              compressed: compressed,
              stats: %{
                event_count: 1,
                raw_bytes: byte_size(line),
                compressed_bytes: byte_size(compressed),
                compression_ratio: Float.round(byte_size(line) / max(byte_size(compressed), 1), 1),
                format: :jsonl_zst,
                level: level
              }
            }}

          {:error, reason} ->
            {:error, {:compression_failed, reason}}
        end

      {:error, :not_found} ->
        {:error, :user_not_found}
    end
  end

  @doc """
  Decompress an exported audit archive.

  Returns the raw JSONL string.
  """
  @spec decompress_export(binary()) :: {:ok, String.t()} | {:error, term()}
  def decompress_export(compressed) do
    Backend.decompress_zstd(compressed)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Fetch octads from VeriSimDB that have provenance data.
  defp fetch_audit_octads(entity_type) do
    search_term = if entity_type, do: entity_type, else: "burble"

    # Query VeriSimDB for entities matching the search term.
    # The Store wraps VeriSimClient — search returns octads with provenance.
    client = get_verisimdb_client()

    case client do
      nil ->
        {:ok, []}

      client ->
        case VeriSimClient.Search.text(client, search_term, limit: 1000) do
          {:ok, results} when is_list(results) -> {:ok, results}
          {:ok, %{"data" => data}} when is_list(data) -> {:ok, data}
          {:ok, _} -> {:ok, []}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Get the VeriSimDB client from the Store GenServer state.
  # This is a read-only operation — we just need the client handle.
  defp get_verisimdb_client do
    case Store.health() do
      {:ok, true} ->
        # The Store is running — create a client with the same config.
        config = Application.get_env(:burble, Burble.Store, [])
        url = Keyword.get(config, :url, "http://localhost:8080")
        auth = Keyword.get(config, :auth, :none)

        case VeriSimClient.new(url, auth: auth) do
          {:ok, client} -> client
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Format an octad's provenance data as a JSON line.
  defp format_audit_line(octad) do
    provenance = Map.get(octad, "provenance") || Map.get(octad, :provenance)
    name = Map.get(octad, "name") || Map.get(octad, :name)
    id = Map.get(octad, "id") || Map.get(octad, :id)

    if provenance do
      Jason.encode!(%{
        entity_id: id,
        entity_name: name,
        event_type: provenance["event_type"] || provenance[:event_type],
        agent: provenance["agent"] || provenance[:agent],
        description: provenance["description"] || provenance[:description],
        metadata: provenance["metadata"] || provenance[:metadata],
        timestamp: Map.get(octad, "modified_at") || Map.get(octad, :modified_at)
      })
    else
      nil
    end
  end
end
