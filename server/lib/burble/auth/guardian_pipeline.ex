# SPDX-License-Identifier: MPL-2.0
#
# Burble.Auth.GuardianPipeline — Plug pipeline for authenticated API routes.
#
# Verifies JWT tokens from the Authorization header and exposes the caller's
# identity as conn.assigns for controllers.
#
# Two bugs were fixed here (2026-10-21):
#
#   1. The pipeline verified with `claims: %{"typ" => "access"}`, so every
#      guest token — issued with typ "guest" by Guardian.create_guest_token/1
#      and accepted by Burble.GrooveVoice — was rejected with 401 on every
#      authenticated API route. Guest joins therefore worked on the socket
#      plane but silently could not use the REST API at all.
#
#   2. `Guardian.Plug.LoadResource` stores the resource under a pipeline-scoped
#      key; it never sets `conn.assigns[:user_id]`. Every authenticated
#      controller reads `conn.assigns[:user_id]` (moderation actor, message
#      author, ...), so they were all operating with a nil caller.

defmodule Burble.Auth.GuardianPipeline do
  @moduledoc """
  Guardian Plug pipeline for authenticated API routes.

  Verifies the JWT bearer token from the `Authorization` header and assigns:

    * `:user_id`      — the `sub` claim (always set for a verified token)
    * `:display_name` — the `dn` claim, if present
    * `:is_guest`     — the `gst` claim, defaulting to false
    * `:current_user` — the loaded resource, when the store has one

  Only access tokens (`typ` = "access") are accepted in this pipeline.
  Refresh and guest tokens are not: refresh tokens must be exchanged at
  `/api/v1/auth/refresh`, and guest access should be handled by a dedicated,
  least-privilege route scope/pipeline.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :burble,
    module: Burble.Auth.Guardian,
    error_handler: Burble.Auth.GuardianErrorHandler

  # Verify the token from the Authorization header (no claim filter here — the
  # type check is a separate, explicit step below so it can accept two types).
  plug Guardian.Plug.VerifyHeader

  # Ensure the token is present and valid.
  plug Guardian.Plug.EnsureAuthenticated

  # Reject any non-access token presented as bearer credentials.
  plug :verify_token_type

  # Load the user resource from the token claims into :current_user. Guests
  # may not exist in the store, so a blank resource is tolerated.
  plug Guardian.Plug.LoadResource, allow_blank: true, key: :current_user

  # Mirror the identity onto the assigns controllers already read.
  plug :assign_caller

  @doc false
  def verify_token_type(conn, _opts) do
    # current_claims/1 reads the pipeline's default claim key, which is the one
    # VerifyHeader populated above.
    case Guardian.Plug.current_claims(conn) do
      %{"typ" => "access"} ->
        conn

      _ ->
        conn
        |> Burble.Auth.GuardianErrorHandler.auth_error({:invalid_token, :wrong_type}, [])
        |> Plug.Conn.halt()
    end
  end

  @doc false
  def assign_caller(conn, _opts) do
    claims = Guardian.Plug.current_claims(conn) || %{}

    conn
    |> Plug.Conn.assign(:user_id, claims["sub"])
    |> Plug.Conn.assign(:display_name, claims["dn"] || "Guest")
    |> Plug.Conn.assign(:is_guest, Map.get(claims, "gst", false) == true)
  end
end
