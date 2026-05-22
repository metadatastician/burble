# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

defmodule Burble.RoomNamerTest do
  use ExUnit.Case, async: true
  
  describe "RoomNamer" do
    test "generate_room_name/0 returns a string" do
      room_name = Burble.RoomNamer.generate_room_name()
      assert is_binary(room_name)
    end
    
    test "generate_room_name/0 returns three words separated by hyphens" do
      room_name = Burble.RoomNamer.generate_room_name()
      parts = String.split(room_name, "-")
      assert length(parts) == 3
      assert Enum.all?(parts, &(&1 != ""))
    end
    
    test "generate_room_name/0 only uses lowercase letters" do
      room_name = Burble.RoomNamer.generate_room_name()
      refute String.match?(room_name, ~r/[A-Z]/)
      assert String.match?(room_name, ~r/^[a-z-]+$/)
    end
    
    test "generate_room_name/0 produces different names on multiple calls" do
      name1 = Burble.RoomNamer.generate_room_name()
      name2 = Burble.RoomNamer.generate_room_name()
      # Very unlikely to be the same
      assert name1 != name2
    end
    
    test "valid_room_name?/1 returns true for valid room names" do
      assert Burble.RoomNamer.valid_room_name?("apple-banana-cat")
      assert Burble.RoomNamer.valid_room_name?("house-dog-tree")
      assert Burble.RoomNamer.valid_room_name?("xyz-abc-def")
    end
    
    test "valid_room_name?/1 returns false for invalid room names" do
      refute Burble.RoomNamer.valid_room_name?("apple")
      refute Burble.RoomNamer.valid_room_name?("apple-banana")
      refute Burble.RoomNamer.valid_room_name?("apple-banana-cat-dog")
      refute Burble.RoomNamer.valid_room_name?("Apple-banana-cat")
      refute Burble.RoomNamer.valid_room_name?("apple1-banana-cat")
      refute Burble.RoomNamer.valid_room_name?("apple-banana-cat!")
      refute Burble.RoomNamer.valid_room_name?("")
    end
    
    test "generated room names are always valid" do
      Enum.each(1..100, fn _ ->
        room_name = Burble.RoomNamer.generate_room_name()
        assert Burble.RoomNamer.valid_room_name?(room_name)
      end)
    end
    
    test "room names use only words from the wordlist" do
      room_name = Burble.RoomNamer.generate_room_name()
      words = String.split(room_name, "-")
      
      wordlist = Burble.RoomNamer.wordlist()
      
      assert Enum.all?(words, &(&1 in wordlist))
    end
  end
end
