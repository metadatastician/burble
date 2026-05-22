# SPDX-License-Identifier: MPL-2.0
defmodule Burble.Network.TurnCredentialsTest do
  use ExUnit.Case, async: true

  alias Burble.Network.TurnCredentials

  describe "generate_credentials/2" do
    test "returns a username and base64 credential" do
      {username, credential} = TurnCredentials.generate_credentials("user123", "secret")
      assert String.contains?(username, ":user123")
      assert {:ok, _} = Base.decode64(credential)
    end

    test "username contains a unix timestamp expiry" do
      now = System.system_time(:second)
      {username, _} = TurnCredentials.generate_credentials("alice", "secret")
      [expiry_str, _user] = String.split(username, ":", parts: 2)
      expiry = String.to_integer(expiry_str)
      assert expiry > now
      assert expiry < now + 90_000
    end

    test "different secrets produce different credentials for same user" do
      {_, cred_a} = TurnCredentials.generate_credentials("user", "secret_a")
      {_, cred_b} = TurnCredentials.generate_credentials("user", "secret_b")
      refute cred_a == cred_b
    end

    test "different users produce different usernames" do
      {username_a, _} = TurnCredentials.generate_credentials("alice", "secret")
      {username_b, _} = TurnCredentials.generate_credentials("bob", "secret")
      refute username_a == username_b
    end
  end

  describe "ice_servers/1" do
    setup do
      original_stun = Application.get_env(:burble, :stun_url)
      original_turn = Application.get_env(:burble, :turn_url)
      original_turns = Application.get_env(:burble, :turns_url)
      original_secret = Application.get_env(:burble, :turn_secret)

      on_exit(fn ->
        Application.put_env(:burble, :stun_url, original_stun)
        Application.put_env(:burble, :turn_url, original_turn)
        Application.put_env(:burble, :turns_url, original_turns)
        Application.put_env(:burble, :turn_secret, original_secret)
      end)

      :ok
    end

    test "returns at least one STUN server" do
      Application.put_env(:burble, :stun_url, "stun:stun.example.com:3478")
      Application.put_env(:burble, :turn_url, nil)
      Application.put_env(:burble, :turn_secret, nil)

      servers = TurnCredentials.ice_servers("user")
      assert length(servers) >= 1
      assert Enum.any?(servers, &String.starts_with?(&1.urls, "stun:"))
    end

    test "includes TURN servers when secret and turn_url are configured" do
      Application.put_env(:burble, :stun_url, "stun:stun.example.com:3478")
      Application.put_env(:burble, :turn_url, "turn:turn.example.com:3478")
      Application.put_env(:burble, :turns_url, nil)
      Application.put_env(:burble, :turn_secret, "test-secret")

      servers = TurnCredentials.ice_servers("alice")
      turn_servers = Enum.filter(servers, &String.starts_with?(&1.urls, "turn:"))
      assert length(turn_servers) == 1
      [turn] = turn_servers
      assert Map.has_key?(turn, :username)
      assert Map.has_key?(turn, :credential)
    end

    test "includes both TURN and TURNS when both configured" do
      Application.put_env(:burble, :turn_url, "turn:turn.example.com:3478")
      Application.put_env(:burble, :turns_url, "turns:turn.example.com:5349")
      Application.put_env(:burble, :turn_secret, "test-secret")

      servers = TurnCredentials.ice_servers("alice")
      assert Enum.any?(servers, &String.starts_with?(&1.urls, "turn:"))
      assert Enum.any?(servers, &String.starts_with?(&1.urls, "turns:"))
    end

    test "falls back to STUN only when no secret configured" do
      Application.put_env(:burble, :turn_url, "turn:turn.example.com:3478")
      Application.put_env(:burble, :turn_secret, nil)

      servers = TurnCredentials.ice_servers("alice")
      refute Enum.any?(servers, &String.starts_with?(&1.urls, "turn:"))
    end

    test "uses default Google STUN when no STUN_URL configured" do
      Application.delete_env(:burble, :stun_url)
      Application.put_env(:burble, :turn_secret, nil)

      servers = TurnCredentials.ice_servers()
      assert Enum.any?(servers, &String.contains?(&1.urls, "google"))
    end
  end
end
