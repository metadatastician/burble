# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BurbleWeb.API.RTSPController — HTTP status endpoint for the RTSP transport.
#
# Returns the list of active RTSP mountpoints and the control port so that
# operators and monitoring systems can inspect broadcast/stage room streams.

defmodule BurbleWeb.API.RTSPController do
  @moduledoc """
  RTSP transport status endpoint.

  `GET /api/v1/rtsp/status` returns:
  - `mountpoints` — list of active RTSP mountpoint paths with subscriber
    counts and RTP packet counts.
  - `port` — the TCP port the RTSP control listener is bound to (default 8554).
  """

  use Phoenix.Controller, formats: [:json]

  alias Burble.Transport.RTSP

  @doc """
  Return the current RTSP transport status.

  Response shape:

      {
        "mountpoints": [
          {"path": "/live/room-abc/speaker", "subscribers": 3, "packets": 1024}
        ],
        "port": 8554
      }
  """
  def status(conn, _params) do
    mountpoints =
      RTSP.list_mountpoints()
      |> Enum.map(fn {path, subscribers, packets} ->
        %{path: path, subscribers: subscribers, packets: packets}
      end)

    port = Application.get_env(:burble, RTSP, []) |> Keyword.get(:port, 8554)

    json(conn, %{
      mountpoints: mountpoints,
      port: port
    })
  end
end
