# SPDX-License-Identifier: MPL-2.0

defmodule BurbleWeb.API.ServerController do
  use Phoenix.Controller, formats: [:json]

  # MVP: single hardcoded server. Multi-server from database later.
  def index(conn, _params) do
    json(conn, %{servers: [%{id: "default", name: "Burble Server", room_count: 0}]})
  end

  def create(conn, _params) do
    json(conn, %{id: "default", name: "Burble Server"})
  end

  def show(conn, %{"id" => _id}) do
    json(conn, %{id: "default", name: "Burble Server", room_count: 0, member_count: 0})
  end
end
