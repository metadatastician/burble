# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BurbleWeb.Plugs.GroovePlug — HTTP handler for groove discovery endpoints.
#
# Handles the /.well-known/groove/* paths that Gossamer (and other
# groove-aware systems) probe to discover Burble's capabilities.
#
# Routes:
#   GET  /.well-known/groove            → JSON manifest (static)
#   POST /.well-known/groove/message    → Receive message from consumer
#   GET  /.well-known/groove/recv       → Drain pending messages for consumer
#   POST /.well-known/groove/connect    → Establish groove connection (spec 4.2)
#   POST /.well-known/groove/disconnect → Tear down groove connection (spec 4.5)
#   GET  /.well-known/groove/heartbeat  → Heartbeat keepalive (spec 4.3)
#   GET  /.well-known/groove/status     → Current connection states
#
# This plug is designed to be inserted early in the pipeline (before
# the router) so that groove discovery works regardless of other
# middleware configuration.

defmodule BurbleWeb.Plugs.GroovePlug do
  @moduledoc """
  Plug for groove discovery endpoints.

  Inserted into the Endpoint before the router. Handles the lightweight
  HTTP protocol that Gossamer's groove.zig uses to discover services.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  # GET /.well-known/groove — Return the capability manifest.
  def call(
        %Plug.Conn{method: "GET", path_info: [".well-known", "groove"]} = conn,
        _opts
      ) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Burble.Groove.manifest_json())
    |> halt()
  end

  # POST /.well-known/groove/message — Receive a message from a consumer.
  # Note: Plug.Parsers has already consumed the body by this point in the
  # endpoint pipeline, so we read from conn.body_params (parsed JSON) or
  # fall back to read_body for raw HTTP/1.0 requests from Zig groove probes.
  #
  # Body size is implicitly limited by Plug.Parsers (:length default = 8MB).
  # Groove messages are typically < 1KB, so this is generous.
  def call(
        %Plug.Conn{method: "POST", path_info: [".well-known", "groove", "message"]} = conn,
        _opts
      ) do
    message =
      case conn.body_params do
        %Plug.Conn.Unfetched{} ->
          # Body not yet parsed (e.g. raw HTTP/1.0 from Zig groove client).
          case Plug.Conn.read_body(conn) do
            {:ok, body, _conn} -> Jason.decode(body)
            _ -> {:error, :no_body}
          end

        %{"_json" => json} when is_map(json) ->
          {:ok, json}

        params when is_map(params) and map_size(params) > 0 ->
          {:ok, params}

        _ ->
          {:error, :empty}
      end

    case message do
      {:ok, msg} ->
        Burble.Groove.push_message(msg)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, ~s({"ok":true}))
        |> halt()

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, ~s({"ok":false,"error":"invalid JSON"}))
        |> halt()
    end
  end

  # GET /.well-known/groove/recv — Drain pending messages.
  # Handles gracefully if the Groove GenServer hasn't started yet.
  def call(
        %Plug.Conn{method: "GET", path_info: [".well-known", "groove", "recv"]} = conn,
        _opts
      ) do
    messages =
      try do
        Burble.Groove.pop_messages()
      catch
        :exit, _ -> []
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(messages))
    |> halt()
  end

  # POST /.well-known/groove/connect — Establish a groove connection.
  #
  # The consumer sends its manifest. Burble checks structural compatibility
  # (does the consumer consume something we offer?) and returns a session ID.
  # Per spec section 4.2: DISCOVERED -> NEGOTIATING -> CONNECTED.
  def call(
        %Plug.Conn{method: "POST", path_info: [".well-known", "groove", "connect"]} = conn,
        _opts
      ) do
    peer_manifest = parse_json_body(conn)

    case peer_manifest do
      {:ok, manifest} ->
        case Burble.Groove.connect(manifest) do
          {:ok, session_id} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              200,
              Jason.encode!(%{
                ok: true,
                session_id: session_id,
                provider: "burble",
                state: "connected"
              })
            )
            |> halt()

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              409,
              Jason.encode!(%{ok: false, error: reason, state: "rejected"})
            )
            |> halt()
        end

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, ~s({"ok":false,"error":"invalid JSON body"}))
        |> halt()
    end
  end

  # POST /.well-known/groove/disconnect — Tear down a groove connection.
  #
  # Consumes the linear connection handle. Per spec section 4.5.
  # Expects JSON body with "session_id".
  def call(
        %Plug.Conn{method: "POST", path_info: [".well-known", "groove", "disconnect"]} = conn,
        _opts
      ) do
    case parse_json_body(conn) do
      {:ok, %{"session_id" => session_id}} when is_binary(session_id) ->
        case Burble.Groove.disconnect(session_id) do
          :ok ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              200,
              Jason.encode!(%{ok: true, state: "disconnected"})
            )
            |> halt()

          {:error, :not_found} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(404, ~s({"ok":false,"error":"session not found"}))
            |> halt()
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, ~s({"ok":false,"error":"missing session_id"}))
        |> halt()
    end
  end

  # GET /.well-known/groove/heartbeat — Heartbeat from connected peer.
  #
  # Per spec section 4.3. Returns 204 No Content on success.
  # Expects ?session_id= query parameter.
  def call(
        %Plug.Conn{method: "GET", path_info: [".well-known", "groove", "heartbeat"]} = conn,
        _opts
      ) do
    conn = Plug.Conn.fetch_query_params(conn)
    session_id = conn.query_params["session_id"]

    case session_id do
      nil ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, ~s({"ok":false,"error":"missing session_id query parameter"}))
        |> halt()

      sid ->
        case Burble.Groove.heartbeat(sid) do
          :ok ->
            conn
            |> send_resp(204, "")
            |> halt()

          {:error, :not_found} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(404, ~s({"ok":false,"error":"session not found"}))
            |> halt()
        end
    end
  end

  # GET /.well-known/groove/status — Current connection state for all peers.
  #
  # Returns a JSON object keyed by session_id with connection info.
  def call(
        %Plug.Conn{method: "GET", path_info: [".well-known", "groove", "status"]} = conn,
        _opts
      ) do
    status =
      try do
        Burble.Groove.connection_status()
      catch
        :exit, _ -> %{}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(status))
    |> halt()
  end

  # GET /.well-known/groove/mesh — Inter-service health mesh status.
  #
  # Returns the cached health view of all groove peers that this node
  # monitors. Each peer entry includes service_id, port, status, and
  # last_seen timestamp. Per spec section 6 (mesh composition).
  def call(
        %Plug.Conn{method: "GET", path_info: [".well-known", "groove", "mesh"]} = conn,
        _opts
      ) do
    mesh =
      try do
        Burble.Groove.HealthMesh.mesh_status()
      catch
        :exit, _ -> %{service_id: "burble", peers: [], error: "health mesh not started"}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(mesh))
    |> halt()
  end

  # POST /.well-known/groove/feedback — Receive feedback routed via Groove.
  #
  # Schema: { "type": "feedback", "target_service": string,
  #           "category": string, "message": string, "metadata": object }
  #
  # If target_service is "burble" (or omitted), stores locally.
  # Otherwise, attempts to route to the target via the health mesh.
  def call(
        %Plug.Conn{method: "POST", path_info: [".well-known", "groove", "feedback"]} = conn,
        _opts
      ) do
    case parse_json_body(conn) do
      {:ok, event} ->
        target = Map.get(event, "target_service", "burble")

        if target == "burble" do
          case Burble.Groove.Feedback.accept(event) do
            {:ok, id} ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(
                200,
                Jason.encode!(%{ok: true, routed_to: "burble", id: id})
              )
              |> halt()

            {:error, reason} ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(400, Jason.encode!(%{ok: false, error: reason}))
              |> halt()
          end
        else
          # Route to peer via mesh — find peer port and forward.
          case route_feedback_to_peer(target, event) do
            :ok ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, Jason.encode!(%{ok: true, routed_to: target}))
              |> halt()

            {:error, reason} ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(
                502,
                Jason.encode!(%{ok: false, error: "routing failed: #{reason}", target_service: target})
              )
              |> halt()
          end
        end

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, ~s({"ok":false,"error":"invalid JSON body"}))
        |> halt()
    end
  end

  # Pass through everything else.
  def call(conn, _opts), do: conn

  # --- Helpers ---

  # Route a feedback event to a peer service via the health mesh.
  #
  # Looks up the peer in the mesh status and POSTs the feedback to their
  # /.well-known/groove/feedback endpoint.
  defp route_feedback_to_peer(target, event) do
    mesh =
      try do
        Burble.Groove.HealthMesh.mesh_status()
      catch
        :exit, _ -> %{peers: []}
      end

    case Enum.find(mesh.peers, fn p -> p.service_id == target and p.status == :up end) do
      nil ->
        {:error, "peer '#{target}' not found or not up in mesh"}

      peer ->
        body = Jason.encode!(event)

        case :gen_tcp.connect(~c"127.0.0.1", peer.port, [:binary, active: false], 2_000) do
          {:ok, socket} ->
            request =
              "POST /.well-known/groove/feedback HTTP/1.0\r\n" <>
                "Host: 127.0.0.1:#{peer.port}\r\n" <>
                "Content-Type: application/json\r\n" <>
                "Content-Length: #{byte_size(body)}\r\n" <>
                "Connection: close\r\n\r\n" <>
                body

            :gen_tcp.send(socket, request)
            :gen_tcp.close(socket)
            :ok

          {:error, reason} ->
            {:error, "tcp connect failed: #{inspect(reason)}"}
        end
    end
  end

  # Parse JSON from the request body, handling both pre-parsed and raw bodies.
  defp parse_json_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        case Plug.Conn.read_body(conn) do
          {:ok, body, _conn} -> Jason.decode(body)
          _ -> {:error, :no_body}
        end

      %{"_json" => json} when is_map(json) ->
        {:ok, json}

      params when is_map(params) and map_size(params) > 0 ->
        {:ok, params}

      _ ->
        {:error, :empty}
    end
  end
end
