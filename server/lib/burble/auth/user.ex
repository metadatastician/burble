# SPDX-License-Identifier: MPL-2.0
#
# Burble.Auth.User — User account struct and validation.
#
# Pure data struct with validation functions. No Ecto dependency.
# Persistence is handled by Burble.Store (VeriSimDB octad entities).

defmodule Burble.Auth.User do
  @moduledoc """
  User account for Burble.

  Users can be full accounts (email + password) or guest sessions.
  Full accounts persist across sessions and can own/admin servers.

  This module defines the user struct and provides changeset-style
  validation without Ecto. Validation returns `{:ok, attrs}` or
  `{:error, errors}` where errors is a keyword list.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          email: String.t() | nil,
          display_name: String.t() | nil,
          password_hash: String.t() | nil,
          is_admin: boolean(),
          mfa_enabled: boolean(),
          mfa_secret: String.t() | nil,
          last_seen_at: String.t() | nil,
          inserted_at: String.t() | nil,
          updated_at: String.t() | nil
        }

  defstruct [
    :id,
    :email,
    :display_name,
    :password_hash,
    :mfa_secret,
    :last_seen_at,
    :inserted_at,
    :updated_at,
    is_admin: false,
    mfa_enabled: false
  ]

  @email_regex ~r/^[^\s]+@[^\s]+\.[^\s]+$/

  @doc """
  Validate registration attributes and hash the password.

  Returns `{:ok, validated_attrs}` with `:password_hash` set and
  `:password` removed, or `{:error, errors}` with a map of field errors.
  """
  @spec validate_registration(map()) :: {:ok, map()} | {:error, map()}
  def validate_registration(attrs) do
    email = Map.get(attrs, :email) || Map.get(attrs, "email")
    display_name = Map.get(attrs, :display_name) || Map.get(attrs, "display_name")
    password = Map.get(attrs, :password) || Map.get(attrs, "password")

    errors =
      []
      |> validate_required(:email, email)
      |> validate_required(:display_name, display_name)
      |> validate_required(:password, password)
      |> validate_email_format(email)
      |> validate_length(:display_name, display_name, 1, 32)
      |> validate_length(:password, password, 8, 128)
      |> validate_password_strength(password)
      |> validate_not_common_password(password)

    if errors == [] do
      {:ok,
       %{
         email: String.downcase(email),
         display_name: display_name,
         password_hash: Bcrypt.hash_pwd_salt(password),
         is_admin: false,
         mfa_enabled: false
       }}
    else
      {:error, errors_to_map(errors)}
    end
  end

  @doc "Convert a map (e.g. from Burble.Store) into a User struct."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map[:id] || map["id"],
      email: map[:email] || map["email"],
      display_name: map[:display_name] || map["display_name"],
      password_hash: map[:password_hash] || map["password_hash"],
      is_admin: map[:is_admin] || map["is_admin"] || false,
      mfa_enabled: map[:mfa_enabled] || map["mfa_enabled"] || false,
      mfa_secret: map[:mfa_secret] || map["mfa_secret"],
      last_seen_at: map[:last_seen_at] || map["last_seen_at"],
      inserted_at: map[:inserted_at] || map["inserted_at"],
      updated_at: map[:updated_at] || map["updated_at"]
    }
  end

  # ---------------------------------------------------------------------------
  # Private validation helpers
  # ---------------------------------------------------------------------------

  defp validate_required(errors, field, nil), do: [{field, "can't be blank"} | errors]
  defp validate_required(errors, field, val) when is_binary(val) do
    if String.trim(val) == "", do: [{field, "can't be blank"} | errors], else: errors
  end
  defp validate_required(errors, _field, _val), do: errors

  defp validate_email_format(errors, nil), do: errors
  defp validate_email_format(errors, email) when is_binary(email) do
    if Regex.match?(@email_regex, email), do: errors, else: [{:email, "must be a valid email"} | errors]
  end
  defp validate_email_format(errors, _), do: errors

  defp validate_length(errors, _field, nil, _min, _max), do: errors
  defp validate_length(errors, field, val, min, max) when is_binary(val) do
    len = String.length(val)
    cond do
      len < min -> [{field, "should be at least #{min} character(s)"} | errors]
      len > max -> [{field, "should be at most #{max} character(s)"} | errors]
      true -> errors
    end
  end
  defp validate_length(errors, _field, _val, _min, _max), do: errors

  defp validate_password_strength(errors, nil), do: errors
  defp validate_password_strength(errors, password) when is_binary(password) do
    case Burble.Safety.ProvenBridge.validate_password_strength(password) do
      {:ok, _} -> errors
      {:error, {:too_weak, level}} -> [{:password, "too weak (#{level})"} | errors]
      {:error, _} -> [{:password, "does not meet strength requirements"} | errors]
    end
  end
  defp validate_password_strength(errors, _), do: errors

  defp validate_not_common_password(errors, nil), do: errors
  defp validate_not_common_password(errors, password) when is_binary(password) do
    if Burble.Safety.ProvenBridge.common_password?(password),
      do: [{:password, "is a commonly used password"} | errors],
      else: errors
  end
  defp validate_not_common_password(errors, _), do: errors

  # Group errors by field name into a map (mirrors Ecto.Changeset.traverse_errors output).
  defp errors_to_map(errors) do
    errors
    |> Enum.reverse()
    |> Enum.group_by(fn {field, _msg} -> field end, fn {_field, msg} -> msg end)
  end
end
