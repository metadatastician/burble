# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

defmodule Burble.Store.Backup do
  @moduledoc """
  Disaster-recovery backups for the VeriSimDB-backed Burble store.

  A backup is a gzipped JSONL file: one octad per line, one file per
  invocation, named `verisim-backup-YYYYMMDDTHHMMSSZ.jsonl.gz`. Each line is
  the full octad map returned by VeriSimDB, so every modality (document,
  provenance, temporal, etc.) is preserved.

  ## Restore

  Restore is intentionally not automated — replaying a backup overwrites
  live state and warrants a human-in-the-loop. To restore manually:

      iex> File.stream!(path, [:compressed])
      ...> |> Stream.map(&Jason.decode!/1)
      ...> |> Enum.each(&VeriSimClient.Octad.create(client, &1))

  ## Prefixes

  By default we back up every entity prefix the Burble store writes
  (`@default_prefixes`). Pass `:prefixes` to override.
  """

  require Logger

  @default_prefixes ~w(user: room_config: server_config: invite: magic:)
  @default_dir "priv/backups"

  @type opts :: [
          dir: String.t(),
          store: module(),
          prefixes: [String.t()],
          per_prefix_limit: pos_integer()
        ]

  @type result :: %{
          path: String.t(),
          octad_count: non_neg_integer(),
          byte_size: non_neg_integer(),
          duration_ms: non_neg_integer(),
          per_prefix: %{String.t() => non_neg_integer()}
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Run a backup. Returns `{:ok, result}` on success or `{:error, reason}`.
  """
  @spec run(opts()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) do
    started_at = System.monotonic_time(:millisecond)
    dir = Keyword.get(opts, :dir, default_dir())
    store = Keyword.get(opts, :store, Burble.Store)
    prefixes = Keyword.get(opts, :prefixes, @default_prefixes)
    limit = Keyword.get(opts, :per_prefix_limit, 10_000)

    with :ok <- File.mkdir_p(dir),
         {:ok, by_prefix} <- collect_octads(store, prefixes, limit),
         path = Path.join(dir, filename()),
         :ok <- write_gzipped_jsonl(path, by_prefix) do
      total_count = by_prefix |> Map.values() |> List.flatten() |> length()
      per_prefix = Map.new(by_prefix, fn {p, octads} -> {p, length(octads)} end)

      byte_size =
        case File.stat(path) do
          {:ok, %{size: n}} -> n
          _ -> 0
        end

      result = %{
        path: path,
        octad_count: total_count,
        byte_size: byte_size,
        duration_ms: System.monotonic_time(:millisecond) - started_at,
        per_prefix: per_prefix
      }

      Logger.info(
        "[Store.Backup] wrote #{total_count} octads to #{path} " <>
          "(#{byte_size} bytes, #{result.duration_ms}ms)"
      )

      :telemetry.execute(
        [:burble, :store, :backup, :ok],
        %{octad_count: total_count, byte_size: byte_size, duration_ms: result.duration_ms},
        %{path: path}
      )

      {:ok, result}
    else
      {:error, reason} = err ->
        Logger.error("[Store.Backup] failed: #{inspect(reason)}")
        :telemetry.execute([:burble, :store, :backup, :error], %{count: 1}, %{reason: reason})
        err
    end
  end

  @doc """
  List existing backup files in `dir`, newest first. Each entry is
  `%{path:, name:, size:, mtime:}`.
  """
  @spec list(String.t() | nil) :: [
          %{path: String.t(), name: String.t(), size: non_neg_integer(), mtime: integer()}
        ]
  def list(dir \\ nil) do
    dir = dir || default_dir()

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&backup_file?/1)
        |> Enum.map(fn name ->
          path = Path.join(dir, name)
          stat = File.stat!(path, time: :posix)
          %{path: path, name: name, size: stat.size, mtime: stat.mtime}
        end)
        |> Enum.sort_by(& &1.mtime, :desc)

      {:error, _} ->
        []
    end
  end

  @doc """
  Keep only the newest `keep` backup files in `dir`; delete the rest.
  Returns the list of deleted paths.
  """
  @spec prune(String.t() | nil, pos_integer()) :: [String.t()]
  def prune(dir \\ nil, keep) when is_integer(keep) and keep >= 1 do
    dir = dir || default_dir()

    list(dir)
    |> Enum.drop(keep)
    |> Enum.map(fn %{path: path} ->
      case File.rm(path) do
        :ok ->
          Logger.info("[Store.Backup] pruned #{path}")
          path

        {:error, reason} ->
          Logger.warning("[Store.Backup] could not prune #{path}: #{inspect(reason)}")
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Default backup directory (`priv/backups` under the burble app)."
  def default_dir do
    case :code.priv_dir(:burble) do
      {:error, _} -> @default_dir
      priv -> Path.join(priv, "backups")
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp collect_octads(store, prefixes, limit) do
    Enum.reduce_while(prefixes, {:ok, %{}}, fn prefix, {:ok, acc} ->
      case store.list_by_prefix(prefix, limit) do
        {:ok, octads} ->
          {:cont, {:ok, Map.put(acc, prefix, octads)}}

        {:error, reason} ->
          {:halt, {:error, {:list_failed, prefix, reason}}}
      end
    end)
  end

  defp write_gzipped_jsonl(path, by_prefix) do
    lines =
      by_prefix
      |> Enum.flat_map(fn {prefix, octads} ->
        Enum.map(octads, fn octad ->
          {:ok, encoded} = Jason.encode(%{prefix: prefix, octad: octad})
          encoded <> "\n"
        end)
      end)

    body = IO.iodata_to_binary(lines)
    File.write(path, :zlib.gzip(body))
  end

  defp filename do
    "verisim-backup-" <>
      (DateTime.utc_now()
       |> DateTime.to_iso8601(:basic)
       |> String.replace(~r/\.\d+/, "")) <>
      ".jsonl.gz"
  end

  defp backup_file?(name) do
    String.starts_with?(name, "verisim-backup-") and String.ends_with?(name, ".jsonl.gz")
  end
end
