# SPDX-License-Identifier: MPL-2.0

defmodule Burble.PermissionsTest do
  use ExUnit.Case, async: true

  alias Burble.Permissions

  describe "role_template/1" do
    test "admin has all permissions" do
      admin = Permissions.role_template(:admin)
      assert MapSet.subset?(MapSet.new(Permissions.all_permissions()), admin)
    end

    test "guest has limited permissions" do
      guest = Permissions.role_template(:guest)
      assert Permissions.has_permission?(guest, :join_room)
      assert Permissions.has_permission?(guest, :speak)
      assert Permissions.has_permission?(guest, :text)
      refute Permissions.has_permission?(guest, :kick)
      refute Permissions.has_permission?(guest, :ban)
      refute Permissions.has_permission?(guest, :manage_server)
    end

    test "member has basic voice and text" do
      member = Permissions.role_template(:member)
      assert Permissions.has_permission?(member, :join_room)
      assert Permissions.has_permission?(member, :speak)
      assert Permissions.has_permission?(member, :whisper)
      assert Permissions.has_permission?(member, :text)
      refute Permissions.has_permission?(member, :kick)
    end

    test "moderator can kick but not ban" do
      mod = Permissions.role_template(:moderator)
      assert Permissions.has_permission?(mod, :kick)
      assert Permissions.has_permission?(mod, :mute_others)
      refute Permissions.has_permission?(mod, :ban)
      refute Permissions.has_permission?(mod, :manage_server)
    end
  end

  describe "effective_permissions/3" do
    test "applies channel allow overrides" do
      member = Permissions.role_template(:member)
      allow = MapSet.new([:priority_speaker])
      effective = Permissions.effective_permissions(member, allow)
      assert Permissions.has_permission?(effective, :priority_speaker)
    end

    test "applies channel deny overrides" do
      member = Permissions.role_template(:member)
      deny = MapSet.new([:speak])
      effective = Permissions.effective_permissions(member, MapSet.new(), deny)
      refute Permissions.has_permission?(effective, :speak)
    end
  end

  describe "can?/4" do
    test "checks permission with channel overrides" do
      member = Permissions.role_template(:member)
      assert Permissions.can?(member, :speak)
      refute Permissions.can?(member, :kick)
    end
  end
end
