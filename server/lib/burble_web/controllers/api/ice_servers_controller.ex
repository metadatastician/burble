# SPDX-License-Identifier: MPL-2.0
#
# BurbleWeb.API.IceServersController — ICE server configuration endpoint.
#
# Browsers call GET /api/v1/ice-servers before opening a room to get
# short-lived STUN/TURN credentials. Credentials are valid for 24 hours
# (HMAC-SHA1 signed, verified by coturn without any database lookup).
#
# Response:
#   {"ice_servers": [{"urls": "stun:..."}, {"urls": "turn:...", "username": "...", "credential": "..."}]}

defmodule BurbleWeb.API.IceServersController do
  use Phoenix.Controller, formats: [:json]

  def index(conn, params) do
    user_id = Map.get(params, "user_id", "anonymous")
    servers = Burble.Network.TurnCredentials.ice_servers(user_id)
    json(conn, %{ice_servers: servers})
  end
end
