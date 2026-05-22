# SPDX-License-Identifier: MPL-2.0

defmodule Burble.Store.BackupTest do
  use ExUnit.Case, async: true

  alias Burble.Store.Backup

  defmodule StubStore do
    @moduledoc false
    def list_by_prefix(prefix, _limit) do
      data = :persistent_term.get({__MODULE__, :data}, %{})
      {:ok, Map.get(data, prefix, [])}
    end

    def set(prefix, octads) do
      current = :persistent_term.get({__MODULE__, :data}, %{})
      :persistent_term.put({__MODULE__, :data}, Map.put(current, prefix, octads))
    end

    def clear, do: :persistent_term.put({__MODULE__, :data}, %{})

    def fail(prefix, reason) do
      :persistent_term.put({__MODULE__, :fail}, {prefix, reason})
    end

    def reset_fail, do: :persistent_term.erase({__MODULE__, :fail})
  end

  defmodule FailingStore do
    @moduledoc false
    def list_by_prefix(_prefix, _limit), do: {:error, :verisimdb_down}
  end

  setup do
    StubStore.clear()
    StubStore.reset_fail()

    dir = Path.join(System.tmp_dir!(), "burble_backup_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "run/1" do
    test "writes a gzipped jsonl file containing every octad", %{dir: dir} do
      StubStore.set("user:", [
        %{"name" => "user:alice@example.com", "document" => %{"content" => "{}"}},
        %{"name" => "user:bob@example.com", "document" => %{"content" => "{}"}}
      ])

      StubStore.set("room_config:", [
        %{"name" => "room_config:abc", "document" => %{"content" => "{}"}}
      ])

      assert {:ok, result} =
               Backup.run(dir: dir, store: StubStore, prefixes: ["user:", "room_config:"])

      assert result.octad_count == 3
      assert result.per_prefix == %{"user:" => 2, "room_config:" => 1}
      assert File.exists?(result.path)
      assert result.byte_size > 0

      lines =
        result.path
        |> File.read!()
        |> :zlib.gunzip()
        |> String.split("\n", trim: true)

      assert length(lines) == 3

      assert Enum.all?(lines, fn line ->
               match?({:ok, %{"prefix" => _, "octad" => _}}, Jason.decode(line))
             end)
    end

    test "returns an error when the store fails", %{dir: dir} do
      assert {:error, {:list_failed, "user:", :verisimdb_down}} =
               Backup.run(dir: dir, store: FailingStore, prefixes: ["user:"])

      assert Backup.list(dir) == []
    end

    test "creates the backup directory if missing", %{dir: dir} do
      refute File.exists?(dir)
      StubStore.set("user:", [])
      assert {:ok, _} = Backup.run(dir: dir, store: StubStore, prefixes: ["user:"])
      assert File.dir?(dir)
    end
  end

  describe "list/1" do
    test "returns backups newest first", %{dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "verisim-backup-20260101T000000Z.jsonl.gz"), "x")
      File.write!(Path.join(dir, "verisim-backup-20260102T000000Z.jsonl.gz"), "x")
      File.write!(Path.join(dir, "not-a-backup.txt"), "x")

      Path.join(dir, "verisim-backup-20260101T000000Z.jsonl.gz") |> File.touch!(1)
      Path.join(dir, "verisim-backup-20260102T000000Z.jsonl.gz") |> File.touch!(2)

      assert [%{name: "verisim-backup-20260102T000000Z.jsonl.gz"}, _older] = Backup.list(dir)
    end

    test "returns [] when the directory does not exist" do
      assert Backup.list("/tmp/definitely-does-not-exist-#{System.unique_integer()}") == []
    end
  end

  describe "prune/2" do
    test "keeps the newest N and deletes the rest", %{dir: dir} do
      File.mkdir_p!(dir)

      paths =
        for i <- 1..5 do
          path = Path.join(dir, "verisim-backup-2026010#{i}T000000Z.jsonl.gz")
          File.write!(path, "x")
          File.touch!(path, i)
          path
        end

      deleted = Backup.prune(dir, 2)

      assert length(deleted) == 3
      remaining = Backup.list(dir) |> Enum.map(& &1.name)
      assert length(remaining) == 2

      [newest, second] = paths |> Enum.reverse() |> Enum.take(2)
      assert Path.basename(newest) in remaining
      assert Path.basename(second) in remaining
    end
  end

  describe "telemetry" do
    test "emits a backup.ok event on success", %{dir: dir} do
      handler_id = "backup-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:burble, :store, :backup, :ok],
        fn _event, measurements, meta, parent ->
          send(parent, {:backup_ok, measurements, meta})
        end,
        self()
      )

      try do
        StubStore.set("user:", [%{"name" => "user:x"}])
        Backup.run(dir: dir, store: StubStore, prefixes: ["user:"])
        assert_receive {:backup_ok, %{octad_count: 1}, %{path: _}}, 500
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
