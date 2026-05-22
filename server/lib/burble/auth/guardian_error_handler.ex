# SPDX-License-Identifier: MPL-2.0
#
# Burble.Auth.GuardianErrorHandler — Error responses for auth failures.

defmodule Burble.Auth.GuardianErrorHandler do
  @moduledoc """
  Handles Guardian authentication errors with JSON responses.
  """

  @behaviour Guardian.Plug.ErrorHandler

  import Plug.Conn

  @impl true
  def auth_error(conn, {type, _reason}, _opts) do
    body = Jason.encode!(%{error: to_string(type), message: error_message(type)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
  end

  defp error_message(:unauthenticated), do: "Authentication required. Provide a valid Bearer token."
  defp error_message(:invalid_token), do: "Token is invalid or malformed."
  defp error_message(:token_expired), do: "Token has expired. Use refresh token to obtain a new one."
  defp error_message(:no_resource_found), do: "User account not found."
  defp error_message(type), do: "Authentication failed: #{type}"
end
