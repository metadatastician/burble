# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

defmodule Burble.LLM.Protocol do
  @moduledoc """
  LLM communication protocol handler.
  
  Handles message framing, authentication, and request processing
  for both QUIC and TCP transports.
  """
  
  require Logger

  @frame_header "LLM\r\n"
  @frame_footer "\r\n\r\n"
  
  @doc """
  Process incoming connection.
  """
  def process_connection(socket, transport \\ :quic) do
    case authenticate(socket) do
      {:ok, user_id} ->
        handle_authenticated(socket, user_id, transport)
      {:error, reason} ->
        send_error(socket, 401, "Unauthorized: #{reason}")
        :gen_tcp.close(socket)
    end
  end
  
  @doc """
  Authenticate client connection.
  """
  def authenticate(socket) do
    # Read auth token (first frame must be AUTH)
    case read_frame(socket) do
      {:ok, %{type: "AUTH", token: token}} ->
        case Burble.Auth.verify_llm_token(token) do
          {:ok, user_id} -> {:ok, user_id}
          {:error, _} -> {:error, "Invalid token"}
        end
      _ ->
        {:error, "Auth required"}
    end
  end
  
  @doc """
  Handle authenticated connection.
  """
  def handle_authenticated(socket, user_id, transport) do
    # Register connection
    :ok = Burble.LLM.Registry.register_connection(user_id, self())
    
    # Process messages
    receive_messages(socket, user_id, transport)
  end
  
  @doc """
  Receive and process messages.
  """
  def receive_messages(socket, user_id, transport) do
    case read_frame(socket) do
      {:ok, frame} ->
        handle_message(frame, socket, user_id, transport)
        receive_messages(socket, user_id, transport)
      {:error, :closed} ->
        :ok
      {:error, reason} ->
        Logger.warning("Connection error: #{reason}")
        :gen_tcp.close(socket)
    end
  end
  
  @doc """
  Handle incoming message.
  """
  def handle_message(%{type: "QUERY", id: msg_id, prompt: prompt}, socket, user_id, _transport) do
    # Process LLM query
    case Burble.LLM.process_query(user_id, prompt) do
      {:ok, response} ->
        send_response(socket, msg_id, "RESPONSE", %{response: response})
      {:error, error} ->
        send_response(socket, msg_id, "ERROR", %{error: to_string(error)})
    end
  end
  
  def handle_message(%{type: "STREAM_START", id: msg_id, prompt: prompt}, socket, user_id, transport) do
    # Start streaming response
    _stream_pid = spawn(fn -> stream_response(user_id, prompt, socket, msg_id, transport) end)
    :ok
  end
  
  defp stream_response(user_id, prompt, socket, msg_id, _transport) do
    Burble.LLM.stream_query(user_id, prompt, fn chunk ->
      send_frame(socket, %{type: "STREAM_CHUNK", id: msg_id, chunk: chunk})
    end)
    
    # Send stream end
    send_frame(socket, %{type: "STREAM_END", id: msg_id})
  rescue
    _ -> send_frame(socket, %{type: "STREAM_ERROR", id: msg_id, error: "Stream failed"})
  end
  
  @doc """
  Read frame from socket.
  """
  def read_frame(socket) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, data} ->
        parse_frame(@frame_header <> data <> @frame_footer)
      {:error, :closed} ->
        {:error, :closed}
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  defp parse_frame(full_data) do
    case String.trim(full_data) do
      "" -> {:error, :empty_frame}
      data ->
        try do
          [_header_line, rest] = String.split(data, "\n", parts: 2)
          [type | lines] = String.split(rest, "\n")

          # Parse headers
          headers = Enum.reduce(lines, %{}, fn line, acc ->
            if String.contains?(line, ":") do
              [key, value] = String.split(line, ":", parts: 2)
              Map.put(acc, String.trim(key), String.trim(value))
            else
              acc
            end
          end)

          {:ok, Map.put(headers, :type, String.upcase(type))}
        rescue
          _ -> {:error, :parse_error}
        end
    end
  end
  
  @doc """
  Send frame to socket.
  """
  def send_frame(socket, data) when is_map(data) do
    frame = build_frame(data)
    :gen_tcp.send(socket, frame)
  end
  
  defp build_frame(%{type: type} = data) do
    headers = Enum.reject(data, fn {k, _} -> k in [:type] end)
    header_lines = Enum.map(headers, fn {k, v} -> "#{k}: #{v}" end)
    
    @frame_header <>
    type <> "\n" <>
    Enum.join(header_lines, "\n") <>
    @frame_footer
  end
  
  @doc """
  Send response message.
  """
  def send_response(socket, msg_id, type, data) do
    frame = Map.merge(data, %{type: type, id: msg_id})
    send_frame(socket, frame)
  end
  
  @doc """
  Send error response.
  """
  def send_error(socket, code, message) do
    error_frame = %{type: "ERROR", code: code, message: message}
    send_frame(socket, error_frame)
  end
end
