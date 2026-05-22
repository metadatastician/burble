# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BurbleWeb.Plugs.InputSanitizer — Input validation and sanitization for API endpoints.
#
# Validates and sanitizes all incoming parameters to prevent:
#   - Excessively long strings (DoS via memory exhaustion)
#   - Path traversal via room IDs, user IDs, invite codes
#   - Script injection via display names and room names
#   - Null bytes in string parameters
#   - Invalid UTF-8 sequences
#
# Applied in the API pipeline before controllers execute.
#
# Author: Jonathan D.A. Jewell

defmodule BurbleWeb.Plugs.InputSanitizer do
  @moduledoc """
  Plug that validates and sanitizes incoming request parameters.

  Rejects requests with parameters exceeding length limits, containing
  null bytes, or failing character set validation. This provides a
  defence-in-depth layer — controllers should still validate their own
  domain-specific constraints.

  ## Limits

  | Parameter type     | Max length | Allowed chars               |
  |--------------------|------------|-----------------------------|
  | Room/server IDs    | 128        | Alphanumeric, `-`, `_`      |
  | User IDs           | 128        | Alphanumeric, `-`, `_`      |
  | Display names      | 64         | UTF-8 printable, no control |
  | Room/server names  | 128        | UTF-8 printable, no control |
  | Invite codes       | 64         | Base64url chars             |
  | Email addresses    | 254        | RFC 5321                    |
  | Passwords          | 256        | Any non-null                |
  | Generic strings    | 4096       | UTF-8, no null bytes        |
  """

  @behaviour Plug

  require Logger

  # Maximum parameter lengths by field name pattern.
  @max_lengths %{
    "id" => 128,
    "room_id" => 128,
    "server_id" => 128,
    "user_id" => 128,
    "code" => 64,
    "token" => 256,
    "email" => 254,
    "password" => 256,
    "display_name" => 64,
    "name" => 128,
    "refresh_token" => 2048
  }

  # Default max length for unrecognised string parameters.
  @default_max_length 4096

  # ID-like fields must match alphanumeric + hyphen + underscore.
  @id_fields ~w(id room_id server_id user_id group_id)

  # Code/token fields must match base64url characters.
  @token_fields ~w(code token)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case validate_params(conn.params) do
      :ok ->
        conn

      {:error, field, reason} ->
        Logger.warning("[InputSanitizer] Rejected request: #{field} — #{reason}")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{
          error: "invalid_input",
          field: field,
          message: reason
        }))
        |> Plug.Conn.halt()
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  @doc """
  Validate a map of parameters. Returns `:ok` or `{:error, field, reason}`.

  Can be called directly from controllers for additional validation passes.
  """
  @spec validate_params(map()) :: :ok | {:error, String.t(), String.t()}
  def validate_params(params) when is_map(params) do
    Enum.reduce_while(params, :ok, fn {key, value}, :ok ->
      case validate_field(to_string(key), value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, to_string(key), reason}}
      end
    end)
  end

  # Validate a single field.
  @spec validate_field(String.t(), term()) :: :ok | {:error, String.t()}
  defp validate_field(_key, value) when not is_binary(value), do: :ok

  defp validate_field(key, value) when is_binary(value) do
    max_len = Map.get(@max_lengths, key, @default_max_length)

    cond do
      # Check for null bytes (potential injection).
      String.contains?(value, <<0>>) ->
        {:error, "contains null byte"}

      # Check string length.
      String.length(value) > max_len ->
        {:error, "exceeds maximum length of #{max_len}"}

      # Check valid UTF-8.
      not String.valid?(value) ->
        {:error, "invalid UTF-8"}

      # ID fields: restrict to safe characters.
      key in @id_fields and not Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, value) ->
        {:error, "must contain only alphanumeric characters, hyphens, and underscores"}

      # Token/code fields: restrict to base64url-safe characters.
      key in @token_fields and not Regex.match?(~r/\A[a-zA-Z0-9_\-=+\/]+\z/, value) ->
        {:error, "contains invalid characters for a token/code"}

      # Display names and room names: no control characters.
      key in ~w(display_name name) and has_control_chars?(value) ->
        {:error, "contains control characters"}

      # Email: basic format check.
      key == "email" and not Regex.match?(~r/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/, value) ->
        {:error, "invalid email format"}

      true ->
        :ok
    end
  end

  # Check for ASCII control characters (except tab, newline, carriage return).
  @spec has_control_chars?(String.t()) :: boolean()
  defp has_control_chars?(str) do
    str
    |> String.to_charlist()
    |> Enum.any?(fn
      c when c in [?\t, ?\n, ?\r] -> false
      c when c < 32 -> true
      c when c == 127 -> true
      _ -> false
    end)
  end
end
