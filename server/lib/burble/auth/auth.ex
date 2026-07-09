# SPDX-License-Identifier: MPL-2.0
#
# Burble.Auth — Authentication and session management.
#
# Supports multiple auth flows:
#   - Email magic link (primary, low-friction)
#   - Guest join (anonymous, limited permissions)
#   - One-time invite tokens
#   - MFA for admins (TOTP)
#
# Sessions are JWT-based via Guardian, with refresh token rotation.
#
# Persistence is backed by VeriSimDB via Burble.Store.

defmodule Burble.Auth do
  @moduledoc """
  Authentication context for Burble.

  Handles user registration, login, guest access, and session management.
  """

  require Logger

  alias Burble.Store
  alias Burble.Auth.User

  @doc "Register a new user account."
  def register_user(attrs) do
    case User.validate_registration(attrs) do
      {:ok, validated} ->
        case Store.create_user(validated) do
          {:ok, user_map} -> {:ok, User.from_map(user_map)}
          {:error, reason} -> {:error, reason}
        end

      {:error, errors} ->
        {:error, errors}
    end
  end

  @doc "Authenticate by email and password."
  def authenticate_by_email(email, password) do
    case Store.get_user_by_email(String.downcase(email)) do
      {:error, :not_found} ->
        # Constant-time comparison to prevent timing attacks.
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      {:ok, user_map} ->
        user = User.from_map(user_map)

        if Bcrypt.verify_pass(password, user.password_hash) do
          Store.record_user_event(user.id, "login_success", %{})
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  @doc "Create a guest session (anonymous, limited permissions)."
  def create_guest_session(display_name) do
    guest_id = "guest_" <> Base.encode16(Burble.Safety.ProvenBridge.secure_random(8), case: :lower)

    {:ok,
     %{
       id: guest_id,
       display_name: display_name || "Guest",
       is_guest: true,
       permissions: [:join_room, :speak, :text]
     }}
  end

  @doc """
  Generate a magic link token for passwordless login.

  Stores the token in VeriSimDB with a 15-minute expiry via the
  temporal modality.
  """
  def generate_magic_link(email) do
    token = Base.url_encode64(Burble.Safety.ProvenBridge.secure_random(32), padding: false)

    case Store.store_magic_link(token, email) do
      {:ok, _} ->
        # Send the magic link email.
        base_url = Application.get_env(:burble, :base_url, "http://localhost:6473")
        email_msg = Burble.Email.magic_link(email, token, base_url)
        Burble.Mailer.deliver(email_msg)
        {:ok, token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validate a magic link token and return the associated email.

  Consumes the token (one-time use). Returns `{:error, :expired}` if
  the 15-minute window has passed.
  """
  def verify_magic_link(token) do
    Store.consume_magic_link(token)
  end

  @doc """
  Generate a one-time invite token for a server.

  Stores the invite in VeriSimDB with temporal expiry and use-count
  tracking via the document modality.
  """
  def generate_invite_token(server_id, opts \\ []) do
    max_uses = Keyword.get(opts, :max_uses, 1)
    expires_in = Keyword.get(opts, :expires_in, 86_400)
    token = Base.url_encode64(Burble.Safety.ProvenBridge.secure_random(16), padding: false)

    invite = %{
      token: token,
      server_id: server_id,
      max_uses: max_uses,
      expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second),
      uses: 0
    }

    Store.store_invite(invite)
  end

  @doc """
  Validate and consume an invite token.

  Increments the use count. Returns `{:error, :exhausted}` if max_uses
  reached, `{:error, :expired}` if past expiry.
  """
  def redeem_invite(token) do
    Store.consume_invite(token)
  end

  @doc """
  Verify an LLM service authentication token.
  """
  def verify_llm_token(token) do
    if Mix.env() == :prod do
      # In production a real JWT verifier is required; reject anything without one.
      {:error, :jwt_required}
    else
      Logger.debug("[Auth] verify_llm_token: dev mode, skipping real JWT verification")
      if is_binary(token) and byte_size(token) > 0 do
        {:ok, "user_dev_from_token"}
      else
        {:error, :invalid_token}
      end
    end
  end
end
