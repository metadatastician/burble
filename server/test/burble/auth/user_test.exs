# SPDX-License-Identifier: MPL-2.0

defmodule Burble.Auth.UserTest do
  use ExUnit.Case, async: true

  alias Burble.Auth.User

  # Test fixture password — not a real credential.
  @test_password String.duplicate("a", 16)

  describe "validate_registration/1" do
    test "accepts valid registration attrs" do
      attrs = %{email: "test@example.com", display_name: "Test User", password: @test_password}
      assert {:ok, validated} = User.validate_registration(attrs)
      assert validated.email == "test@example.com"
      assert validated.display_name == "Test User"
      assert is_binary(validated.password_hash)
      assert validated.is_admin == false
    end

    test "rejects missing email" do
      attrs = %{display_name: "Test", password: @test_password}
      assert {:error, errors} = User.validate_registration(attrs)
      assert Map.has_key?(errors, :email)
    end

    test "rejects missing password" do
      attrs = %{email: "test@example.com", display_name: "Test"}
      assert {:error, errors} = User.validate_registration(attrs)
      assert Map.has_key?(errors, :password)
    end

    test "rejects short password" do
      attrs = %{email: "test@example.com", display_name: "Test", password: "ab"}
      assert {:error, errors} = User.validate_registration(attrs)
      assert Map.has_key?(errors, :password)
    end

    test "rejects invalid email format" do
      attrs = %{email: "not-an-email", display_name: "Test", password: @test_password}
      assert {:error, errors} = User.validate_registration(attrs)
      assert Map.has_key?(errors, :email)
    end

    test "normalises email to lowercase" do
      attrs = %{email: "TEST@EXAMPLE.COM", display_name: "Test", password: @test_password}
      assert {:ok, validated} = User.validate_registration(attrs)
      assert validated.email == "test@example.com"
    end

    test "rejects display name over 32 characters" do
      attrs = %{email: "t@e.com", display_name: String.duplicate("a", 33), password: @test_password}
      assert {:error, errors} = User.validate_registration(attrs)
      assert Map.has_key?(errors, :display_name)
    end
  end

  describe "from_map/1" do
    test "converts map to User struct" do
      map = %{id: "123", email: "test@example.com", display_name: "Test", password_hash: "hash", is_admin: true}
      user = User.from_map(map)
      assert %User{} = user
      assert user.id == "123"
      assert user.email == "test@example.com"
      assert user.is_admin == true
    end

    test "handles string keys" do
      map = %{"id" => "123", "email" => "test@example.com", "display_name" => "Test"}
      user = User.from_map(map)
      assert user.id == "123"
      assert user.email == "test@example.com"
    end
  end
end
