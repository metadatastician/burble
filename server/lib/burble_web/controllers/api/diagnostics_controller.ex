# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BurbleWeb.API.DiagnosticsController — HTTP endpoint for self-test diagnostics.
#
# Exposes the self-test system via REST API so web and desktop clients
# can run diagnostics before joining voice rooms.

defmodule BurbleWeb.API.DiagnosticsController do
  use Phoenix.Controller, formats: [:json]

  alias Burble.Diagnostics.SelfTest

  @doc """
  Run a self-test diagnostic.

  GET /api/v1/diagnostics/self-test/:mode

  Modes: quick, voice, full
  Returns structured JSON with pass/fail per subsystem and timing data.
  """
  def self_test(conn, %{"mode" => mode_str}) do
    mode =
      case mode_str do
        "quick" -> :quick
        "voice" -> :voice
        "full" -> :full
        _ -> :quick
      end

    {:ok, results} = SelfTest.run(mode)
    json(conn, results)
  end

  def self_test(conn, _params) do
    {:ok, results} = SelfTest.run(:quick)
    json(conn, results)
  end
end
