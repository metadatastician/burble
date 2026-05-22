# SPDX-License-Identifier: MPL-2.0
#
# Burble.Auth.Guardian — JWT token management via Guardian.
#
# Implements Guardian's serializer callbacks to convert between
# Burble user structs and JWT subjects. Handles:
#
#   - Access tokens (short-lived, 1 hour)
#   - Refresh tokens (long-lived, 30 days, rotatable)
#   - Guest tokens (short-lived, 4 hours, limited claims)
#
# Token structure (JWT claims):
#   sub: user_id or guest_id
#   typ: "access" | "refresh" | "guest"
#   dn:  display_name (custom claim)
#   gst: is_guest flag (custom claim)
#   aud: "burble" (audience — used for cross-server verification)
#
# Cross-server verification (oligarchic/distributed topologies):
#   Guardian signs with a shared secret (monarchic/oligarchic) or
#   asymmetric keys (distributed). Other servers can verify tokens
#   using the standard JWT verification flow with the issuer's public key.

defmodule Burble.Auth.Guardian do
  @moduledoc """
  Guardian JWT implementation for Burble authentication.

  ## Token types

  - `:access` — Short-lived (1 hour). Used for API requests and WebSocket connections.
  - `:refresh` — Long-lived (30 days). Used to obtain new access tokens.
  - `:guest` — Short-lived (4 hours). Limited permissions, no persistence.

  ## Configuration

  In config:

      config :burble, Burble.Auth.Guardian,
        issuer: "burble",
        secret_key: {MyApp.Config, :guardian_secret},
        ttl: {1, :hour}

  ## Usage

      # Encode a token for a user.
      {:ok, token, claims} = Guardian.encode_and_sign(user, %{}, token_type: "access")

      # Decode and verify a token.
      {:ok, claims} = Guardian.decode_and_verify(token)

      # Get the user from claims.
      {:ok, user} = Guardian.resource_from_claims(claims)
  """

  use Guardian, otp_app: :burble

  alias Burble.Store
  alias Burble.Auth.User

  @impl true
  def subject_for_token(%User{id: id}, _claims) do
    {:ok, id}
  end

  def subject_for_token(%{id: id}, _claims) do
    {:ok, to_string(id)}
  end

  def subject_for_token(_, _) do
    {:error, :invalid_resource}
  end

  @impl true
  def resource_from_claims(%{"sub" => user_id, "gst" => true} = claims) do
    # Guest token — reconstruct guest session from claims.
    {:ok, %{
      id: user_id,
      display_name: claims["dn"] || "Guest",
      is_guest: true,
      permissions: [:join_room, :speak, :text]
    }}
  end

  def resource_from_claims(%{"sub" => user_id} = claims) do
    # Regular user — look up from VeriSimDB.
    case Store.get_user(user_id) do
      {:ok, user_map} ->
        {:ok, User.from_map(user_map)}

      {:error, :not_found} ->
        # User may have been deleted — check if we have enough info in claims.
        if claims["dn"] do
          {:ok, %{id: user_id, display_name: claims["dn"], is_guest: false}}
        else
          {:error, :user_not_found}
        end
    end
  end

  def resource_from_claims(_claims) do
    {:error, :invalid_claims}
  end

  # ---------------------------------------------------------------------------
  # Token creation helpers
  # ---------------------------------------------------------------------------

  @doc """
  Create an access token for a registered user.

  Returns `{:ok, token, claims}`.
  """
  def create_access_token(user) do
    encode_and_sign(user, %{
      "dn" => user.display_name,
      "gst" => false
    }, token_type: "access", ttl: {1, :hour})
  end

  @doc """
  Create a refresh token for a registered user.

  Returns `{:ok, token, claims}`. Refresh tokens are long-lived
  and can be exchanged for new access tokens.
  """
  def create_refresh_token(user) do
    encode_and_sign(user, %{
      "dn" => user.display_name,
      "gst" => false
    }, token_type: "refresh", ttl: {30, :day})
  end

  @doc """
  Create a guest access token (short-lived, limited permissions).

  Returns `{:ok, token, claims}`.
  """
  def create_guest_token(guest) do
    encode_and_sign(guest, %{
      "dn" => guest.display_name || guest[:display_name] || "Guest",
      "gst" => true
    }, token_type: "guest", ttl: {4, :hour})
  end

  @doc """
  Exchange a refresh token for a new access + refresh token pair.

  Validates the refresh token, then issues fresh tokens. The old
  refresh token remains valid until it expires (stateless rotation).

  Returns `{:ok, %{access: access_token, refresh: refresh_token}}`.
  """
  def refresh_tokens(refresh_token) do
    with {:ok, claims} <- decode_and_verify(refresh_token, %{"typ" => "refresh"}),
         {:ok, user} <- resource_from_claims(claims),
         {:ok, new_access, _} <- create_access_token(user),
         {:ok, new_refresh, _} <- create_refresh_token(user) do
      {:ok, %{access: new_access, refresh: new_refresh}}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
