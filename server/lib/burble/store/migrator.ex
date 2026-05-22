# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Store.Migrator — Runs VeriSimDB initialization scripts at startup.
#
# VeriSimDB is schemaless, so "migrations" here are idempotent setup scripts
# that ensure the expected namespace prefixes and tracking octads exist.
# Each migration module lives in priv/repo/migrations/ and implements
# version/0, description/0, and up/1.

defmodule Burble.Store.Migrator do
  @moduledoc """
  VeriSimDB migration runner for Burble.

  Called by `Burble.Store` after connecting to VeriSimDB. Loads migration
  modules from `priv/repo/migrations/`, checks the current applied version
  via the `_migration:burble` tracking octad, and runs any unapplied
  migrations in order.

  ## Design

  - Migrations are numbered `.exs` files (001_, 002_, ...) in priv/repo/migrations/
  - Each must define `version/0`, `description/0`, and `up/1`
  - The `up/1` function receives the VeriSimClient connection
  - All migrations must be idempotent (safe to re-run)
  - Migration state is tracked in a VeriSimDB octad (`_migration:burble`)
  """

  require Logger

  @migrations_path "priv/repo/migrations"

  @doc """
  Run all pending migrations against the given VeriSimClient connection.

  Returns `:ok` if all migrations succeed, or `{:error, reason}` on the
  first failure (remaining migrations are skipped).
  """
  @spec run(term()) :: :ok | {:error, term()}
  def run(client) do
    current_version = get_current_version(client)
    migrations = load_migrations()

    pending =
      migrations
      |> Enum.filter(fn {_mod, version, _desc} -> version > current_version end)
      |> Enum.sort_by(fn {_mod, version, _desc} -> version end)

    if pending == [] do
      Logger.info("[Burble.Store.Migrator] VeriSimDB schema is up to date (v#{current_version})")
      :ok
    else
      Logger.info(
        "[Burble.Store.Migrator] Running #{length(pending)} pending migration(s) " <>
          "(current: v#{current_version})"
      )

      Enum.reduce_while(pending, :ok, fn {mod, version, desc}, _acc ->
        Logger.info("[Burble.Store.Migrator] Applying migration v#{version}: #{desc}")

        case mod.up(client) do
          :ok ->
            Logger.info("[Burble.Store.Migrator] Migration v#{version} applied successfully")
            {:cont, :ok}

          {:error, reason} ->
            Logger.error(
              "[Burble.Store.Migrator] Migration v#{version} failed: #{inspect(reason)}"
            )

            {:halt, {:error, {:migration_failed, version, reason}}}
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Load and compile migration modules from priv/repo/migrations/.
  defp load_migrations do
    migrations_dir =
      :burble
      |> :code.priv_dir()
      |> Path.join("repo/migrations")

    # Fallback to relative path during development / mix compile.
    migrations_dir =
      if File.dir?(migrations_dir) do
        migrations_dir
      else
        Path.join(File.cwd!(), @migrations_path)
      end

    case File.ls(migrations_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.reject(&String.starts_with?(&1, "README"))
        |> Enum.sort()
        |> Enum.flat_map(fn file ->
          path = Path.join(migrations_dir, file)

          case Code.compile_file(path) do
            [{mod, _bytecode} | _] ->
              if function_exported?(mod, :version, 0) and function_exported?(mod, :up, 1) do
                desc =
                  if function_exported?(mod, :description, 0),
                    do: mod.description(),
                    else: file

                [{mod, mod.version(), desc}]
              else
                Logger.warning(
                  "[Burble.Store.Migrator] Skipping #{file}: missing version/0 or up/1"
                )

                []
              end

            _ ->
              Logger.warning("[Burble.Store.Migrator] Failed to compile #{file}")
              []
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "[Burble.Store.Migrator] Cannot read migrations dir: #{inspect(reason)}"
        )

        []
    end
  end

  # Query VeriSimDB for the current migration version.
  # Returns 0 if no migration tracking octad exists yet.
  defp get_current_version(client) do
    case VeriSimClient.Search.text(client, "_migration:burble", limit: 1) do
      {:ok, results} when is_list(results) ->
        extract_version(results, "_migration:burble")

      {:ok, %{"data" => data}} when is_list(data) ->
        extract_version(data, "_migration:burble")

      _ ->
        0
    end
  end

  defp extract_version(results, name) do
    case Enum.find(results, fn r ->
           get_in(r, ["name"]) == name || get_in(r, [:name]) == name
         end) do
      nil ->
        0

      octad ->
        doc = get_in(octad, ["document"]) || get_in(octad, [:document]) || %{}
        content = doc["content"] || doc[:content] || "{}"

        parsed =
          case content do
            c when is_binary(c) ->
              case Jason.decode(c) do
                {:ok, map} -> map
                _ -> %{}
              end

            c when is_map(c) ->
              c

            _ ->
              %{}
          end

        parsed["current_version"] || 0
    end
  end
end
