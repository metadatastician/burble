# SPDX-License-Identifier: MPL-2.0
defmodule BurbleWeb.Plugs.GrooveVoicePlug do
  @moduledoc "Authenticated, bounded HTTP transport for the scoped voice adapter."
  import Plug.Conn
  @behaviour Plug
  def init(opts), do: opts

  def call(%{path_info: [".well-known", "groove", "voice", action]} = conn, _) do
    result =
      with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
           {:ok, auth} <- Burble.GrooveVoice.authenticate(token) do
        dispatch(conn, action, auth)
      else
        _ -> {:error, :unauthorized}
      end

    respond(conn, result)
  end

  def call(conn, _), do: conn

  defp dispatch(%{method: "POST"} = conn, "connect", auth) do
    with {:ok, body, _} <- read_body(conn, length: 8192, read_length: 8192, read_timeout: 5000),
         true <- byte_size(body) <= 8192,
         {:ok, params} <- Jason.decode(body),
         {:ok, scope} <- Burble.GrooveVoice.scope(auth, params),
         %{"mode" => mode, "ttl_ms" => ttl} = lease <- params["lease"],
         true <- mode in ["soft", "hard"] and is_integer(ttl) and ttl in 100..3_600_000 do
      Burble.Groove.voice_connect(auth, scope, lease)
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp dispatch(conn, action, auth) when action in ["send", "recv", "heartbeat", "disconnect"] do
    method = if action in ["recv", "heartbeat"], do: "GET", else: "POST"

    with true <- conn.method == method,
         [handle] <- get_req_header(conn, "x-groove-handle"),
         true <- byte_size(handle) in 1..128,
         [peer] <- get_req_header(conn, "x-groove-peer"),
         {:ok, body} <- read_frame(conn, action) do
      Burble.Groove.voice_operation(action, handle, auth, peer, body)
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp dispatch(_, _, _), do: {:error, :invalid_request}

  defp read_frame(conn, "send") do
    with ["application/octet-stream"] <- get_req_header(conn, "content-type"),
         {:ok, body, _} <-
           read_body(conn, length: 16_384, read_length: 16_384, read_timeout: 5000),
         true <- byte_size(body) <= 16_384 do
      {:ok, body}
    else
      _ -> {:error, :invalid_frame}
    end
  end

  defp read_frame(_, _), do: {:ok, <<>>}

  defp respond(conn, {:ok, handle, lease}) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{handle: handle, lease: lease}))
    |> halt()
  end

  defp respond(conn, {:frame, bytes}),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/octet-stream")
      |> send_resp(200, bytes)
      |> halt()

  defp respond(conn, :ok), do: conn |> send_resp(204, "") |> halt()

  defp respond(conn, {:error, reason}) do
    status =
      case reason do
        :unauthorized -> 401
        :forbidden -> 403
        :not_found -> 410
        :capacity -> 503
        :soft_lease -> 409
        _ -> 400
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, "voice request rejected")
    |> halt()
  end
end
