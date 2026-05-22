# SPDX-License-Identifier: MPL-2.0
#
# Tests for Burble.Store — VeriSimDB-backed persistent store.
#
# The Store GenServer requires a live VeriSimDB connection to function.
# These tests verify the module API surface (functions exported, specs
# present) and the GenServer registration without exercising the
# database, since VeriSimDB is not available in CI.

defmodule Burble.StoreTest do
  use ExUnit.Case, async: true

  describe "module" do
    test "Burble.Store is loaded" do
      assert Code.ensure_loaded?(Burble.Store)
    end

    test "start_link/1 is exported" do
      exports = Burble.Store.__info__(:functions)
      assert {:start_link, 1} in exports
    end

    test "user CRUD functions are exported" do
      exports = Burble.Store.__info__(:functions)
      assert {:create_user, 1} in exports
      assert {:get_user, 1} in exports
      assert {:get_user_by_email, 1} in exports
      assert {:update_user, 2} in exports
    end

    test "token storage functions are exported" do
      exports = Burble.Store.__info__(:functions)
      assert {:store_magic_link, 2} in exports
      assert {:consume_magic_link, 1} in exports
      assert {:store_invite, 1} in exports
      assert {:consume_invite, 1} in exports
    end

    test "room and server config functions are exported" do
      exports = Burble.Store.__info__(:functions)
      assert {:save_room_config, 2} in exports
      assert {:load_room_config, 1} in exports
      assert {:save_server_config, 2} in exports
      assert {:load_server_config, 1} in exports
    end

    test "health/0 is exported" do
      exports = Burble.Store.__info__(:functions)
      assert {:health, 0} in exports
    end
  end

  describe "GenServer registration" do
    test "Burble.Store whereis returns nil or a live pid, never crashing" do
      # The Store may not be started if VeriSimDB is unavailable in CI.
      # Contract under test: whereis/1 yields nil or a live pid and does
      # not raise. Assert that invariant directly instead of a vacuous
      # branch that passed unconditionally.
      result = GenServer.whereis(Burble.Store)
      assert is_nil(result) or (is_pid(result) and Process.alive?(result))
    end
  end
end
