# SPDX-License-Identifier: MPL-2.0
#
# Burble.Auth.GuardianPipeline — Plug pipeline for authenticated API routes.
#
# Verifies JWT tokens from the Authorization header and loads the
# user resource into conn.assigns. Unauthenticated requests are
# rejected with 401.

defmodule Burble.Auth.GuardianPipeline do
  @moduledoc """
  Guardian Plug pipeline for authenticated API routes.

  Verifies the JWT bearer token from the `Authorization` header
  and loads the user resource. Used in the router:

      pipeline :authenticated_api do
        plug Burble.Auth.GuardianPipeline
      end
  """

  use Guardian.Plug.Pipeline,
    otp_app: :burble,
    module: Burble.Auth.Guardian,
    error_handler: Burble.Auth.GuardianErrorHandler

  # Verify the token from the Authorization header.
  plug Guardian.Plug.VerifyHeader, claims: %{"typ" => "access"}

  # Ensure the token is present and valid.
  plug Guardian.Plug.EnsureAuthenticated

  # Load the user resource from the token claims.
  plug Guardian.Plug.LoadResource, allow_blank: false
end
