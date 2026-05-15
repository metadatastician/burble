# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Migration 001: Initial VeriSimDB setup for Burble.
#
# Creates the namespace prefixes and seed octads that Burble expects.
# This script is idempotent -- safe to run multiple times.

defmodule Burble.Store.Migrations.InitialSetup do
  @moduledoc """
  Initial VeriSimDB namespace setup for Burble.

  Creates octad namespace prefixes:
  - `user:` — User accounts
  - `magic:` — Magic link tokens (ephemeral)
  - `invite:` — Invite tokens
  - `room_config:` — Room configuration
  - `server_config:` — Server/guild configuration
  - `_migration:` — Migration tracking

  Also creates the migration tracking octad itself.
  """

  require Logger

  @version 1
  @description "Initial VeriSimDB schema setup"

  # Maximum attempts for creating the migration tracking octad on fresh-DB boot.
  # VeriSimDB's write endpoint can return 404 on a completely fresh instance
  # (before any octad has ever been created the storage collection is not yet
  # initialised internally).  A brief retry loop absorbs this window.
  @create_max_attempts 3
  @create_retry_delay_ms 1_000

  def version, do: @version
  def description, do: @description

  @doc """
  Run the migration against the given VeriSimClient connection.

  Returns `:ok` on success or `{:error, reason}` on failure.

  Idempotent: running twice is safe.  If the tracking octad already exists
  (VeriSimDB returns 409 Conflict via `{:server_error, 409, _}`, or the octad
  is found via pre-creation search), the function returns `:ok`.
  """
  def up(client) do
    # VeriSimDB is schemaless — octads are created on demand. This migration
    # verifies connectivity and creates the migration tracking octad so that
    # future migrations can check which version has been applied.
    #
    # The namespace prefixes (user:, magic:, invite:, etc.) are conventions
    # enforced by Burble.Store, not VeriSimDB-level constructs.

    # Idempotency guard: if the tracking octad already exists, skip creation.
    # This handles re-runs against a DB that already had migration v1 applied
    # (e.g. rolling restart, or a bug that caused the migrator to re-run).
    case already_applied?(client) do
      true ->
        Logger.info("[InitialSetup] Migration v#{@version} tracking octad already present — skipping create (idempotent)")
        :ok

      false ->
        do_create(client, @create_max_attempts)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Check whether the migration tracking octad already exists in VeriSimDB.
  # Returns true if found, false if absent or if the search endpoint is not
  # yet available (fresh DB — conservative: assume absent and let do_create run).
  defp already_applied?(client) do
    case VeriSimClient.Search.text(client, "_migration:burble", limit: 1) do
      {:ok, results} when is_list(results) ->
        Enum.any?(results, fn r ->
          get_in(r, ["name"]) == "_migration:burble" ||
            get_in(r, [:name]) == "_migration:burble"
        end)

      {:ok, %{"data" => data}} when is_list(data) ->
        Enum.any?(data, fn r ->
          get_in(r, ["name"]) == "_migration:burble" ||
            get_in(r, [:name]) == "_migration:burble"
        end)

      # Search endpoint not available (fresh DB) or returned non-list body.
      # Treat as "not applied" — do_create will attempt to create the octad.
      _ ->
        false
    end
  end

  # Attempt to create the migration tracking octad with retry for the
  # fresh-DB case where VeriSimDB's write endpoint transiently returns 404.
  #
  # On a completely fresh VeriSimDB instance, before any octad has ever been
  # written, the server's internal octad collection has not been created yet.
  # VeriSimDB returns HTTP 404 (empty body) in this state, which VeriSimClient
  # normalises to `{:error, {:not_found, ""}}`.  This is a transient condition:
  # once VeriSimDB's storage layer initialises (triggered by the first write
  # attempt), subsequent calls succeed.  We retry up to @create_max_attempts
  # times to absorb this window.
  #
  # All other errors are treated as genuine failures and propagated immediately.
  defp do_create(_client, 0) do
    {:error, {:not_found, "VeriSimDB write endpoint unavailable after retries (fresh-DB init timeout)"}}
  end

  defp do_create(client, attempts_left) do
    migration_octad = build_octad()

    case VeriSimClient.Octad.create(client, migration_octad) do
      {:ok, _octad} ->
        :ok

      # VeriSimDB returns 409 Conflict as {:server_error, 409, _} through
      # VeriSimClient.handle_response/1 (there is no {:conflict, _} clause).
      # Also accept {:conflict, _} defensively in case a future client version
      # normalises 409 to that shape.
      {:error, {:server_error, 409, _}} ->
        Logger.info("[InitialSetup] Tracking octad already exists (409 Conflict) — idempotent OK")
        :ok

      {:error, {:conflict, _}} ->
        Logger.info("[InitialSetup] Tracking octad already exists (conflict) — idempotent OK")
        :ok

      # Fresh-DB transient 404: VeriSimDB's write endpoint not yet initialised.
      # Retry after a brief delay.
      {:error, {:not_found, _}} when attempts_left > 1 ->
        Logger.warning(
          "[InitialSetup] VeriSimDB returned not_found on octad create (fresh-DB init); " <>
            "retrying in #{@create_retry_delay_ms}ms (#{attempts_left - 1} attempt(s) left)"
        )
        Process.sleep(@create_retry_delay_ms)
        do_create(client, attempts_left - 1)

      # {:not_found, _} with no retries left falls to the genuine-error clause.
      # All other errors are propagated immediately.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_octad do
    now = DateTime.to_iso8601(DateTime.utc_now())

    %{
      name: "_migration:burble",
      description: "Burble migration tracking — do not delete",
      metadata: %{entity_type: "burble_migration_tracker"},
      document: %{
        content:
          Jason.encode!(%{
            current_version: @version,
            applied_at: now,
            migrations: [
              %{
                version: @version,
                description: @description,
                applied_at: now
              }
            ]
          }),
        content_type: "application/json",
        metadata: %{schema_version: 1}
      }
    }
  end
end
