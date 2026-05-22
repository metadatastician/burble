# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.API.AuthController — Authentication endpoints.
#
# Issues Guardian JWTs for registered users and guests.
# Supports access + refresh token pair with rotation.

defmodule BurbleWeb.API.AuthController do
  use Phoenix.Controller, formats: [:json]

  alias Burble.Auth
  alias Burble.Auth.Guardian

  @doc "Register a new user account. Returns access + refresh JWT pair."
  def register(conn, %{"email" => email, "display_name" => name, "password" => password}) do
    case Auth.register_user(%{email: email, display_name: name, password: password}) do
      {:ok, user} ->
        {:ok, access_token, _} = Guardian.create_access_token(user)
        {:ok, refresh_token, _} = Guardian.create_refresh_token(user)

        json(conn, %{
          user_id: user.id,
          display_name: user.display_name,
          access_token: access_token,
          refresh_token: refresh_token,
          token_type: "Bearer",
          expires_in: 3600
        })

      {:error, errors} when is_map(errors) ->
        conn |> put_status(422) |> json(%{errors: errors})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{errors: %{base: [inspect(reason)]}})
    end
  end

  @doc "Login with email + password. Returns access + refresh JWT pair."
  def login(conn, %{"email" => email, "password" => password}) do
    case Auth.authenticate_by_email(email, password) do
      {:ok, user} ->
        {:ok, access_token, _} = Guardian.create_access_token(user)
        {:ok, refresh_token, _} = Guardian.create_refresh_token(user)

        json(conn, %{
          user_id: user.id,
          display_name: user.display_name,
          access_token: access_token,
          refresh_token: refresh_token,
          token_type: "Bearer",
          expires_in: 3600
        })

      {:error, _} ->
        conn |> put_status(401) |> json(%{error: "invalid_credentials"})
    end
  end

  @doc "Create a guest session. Returns a short-lived guest JWT."
  def guest(conn, params) do
    name = Map.get(params, "display_name", "Guest")
    {:ok, guest} = Auth.create_guest_session(name)
    {:ok, token, _} = Guardian.create_guest_token(guest)

    json(conn, %{
      user_id: guest.id,
      display_name: guest.display_name,
      access_token: token,
      token_type: "Bearer",
      expires_in: 14_400,
      is_guest: true
    })
  end

  @doc "Exchange a refresh token for a new access + refresh pair."
  def refresh(conn, %{"refresh_token" => refresh_token}) do
    case Guardian.refresh_tokens(refresh_token) do
      {:ok, %{access: access, refresh: refresh}} ->
        json(conn, %{
          access_token: access,
          refresh_token: refresh,
          token_type: "Bearer",
          expires_in: 3600
        })

      {:error, _reason} ->
        conn |> put_status(401) |> json(%{error: "invalid_refresh_token"})
    end
  end

  @doc "Request a magic link for passwordless login."
  def magic_link(conn, %{"email" => email}) do
    case Auth.generate_magic_link(email) do
      {:ok, _token} -> json(conn, %{status: "sent"})
      {:error, reason} -> conn |> put_status(400) |> json(%{error: reason})
    end
  end

  @doc "Logout — client should discard tokens."
  def logout(conn, _params) do
    # Stateless JWT — no server-side revocation.
    # Client discards tokens. Guardian.Plug.sign_out if using sessions.
    json(conn, %{status: "logged_out"})
  end
end
