# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

defmodule BurbleWeb.API.LLMController do
  @moduledoc """
  REST endpoint for server-side LLM queries.

  Either side of the P2P bridge can POST a prompt and get a Claude response
  back. Requires authentication (JWT) in production; dev mode accepts any
  request so the bridge can call it without token setup.

  ## Endpoints

    POST /api/v1/llm/query   — synchronous JSON response
    POST /api/v1/llm/stream  — Server-Sent Events (SSE) streaming
    GET  /api/v1/llm/status  — provider + circuit breaker status

  ## Rate Limiting

  Per-user: 20 queries per minute (keyed by user_id or IP for anonymous).
  """

  use Phoenix.Controller, formats: [:json]
  require Logger

  @max_prompt_length 32_000
  @rate_limit_window_ms 60_000
  @rate_limit_max 20

  # ---------------------------------------------------------------------------
  # POST /api/v1/llm/query
  # ---------------------------------------------------------------------------

  def query(conn, %{"prompt" => prompt}) when byte_size(prompt) <= @max_prompt_length do
    user_id = get_user_id(conn)

    with :ok <- check_rate_limit(user_id) do
      case Burble.LLM.process_query(user_id, prompt) do
        {:ok, text} ->
          json(conn, %{ok: true, response: text})

        {:error, :circuit_open} ->
          conn |> put_status(503) |> json(%{ok: false, error: "circuit_open", retry_after: 30})

        {:error, :no_provider_configured} ->
          conn |> put_status(503) |> json(%{ok: false, error: "llm_not_configured"})

        {:error, :api_key_not_configured} ->
          conn |> put_status(503) |> json(%{ok: false, error: "api_key_not_set"})

        {:error, :pool_exhausted} ->
          conn |> put_status(503) |> json(%{ok: false, error: "busy", retry_after: 5})

        {:error, {:api_error, status}} ->
          conn |> put_status(502) |> json(%{ok: false, error: "upstream_error", status: status})

        {:error, reason} ->
          Logger.warning("[LLMController] Query failed: #{inspect(reason)}")
          conn |> put_status(500) |> json(%{ok: false, error: "internal_error"})
      end
    else
      {:rate_limited, retry_after} ->
        conn
        |> put_status(429)
        |> put_resp_header("retry-after", to_string(retry_after))
        |> json(%{ok: false, error: "rate_limited", retry_after: retry_after})
    end
  end

  def query(conn, %{"prompt" => _prompt}) do
    conn |> put_status(413) |> json(%{ok: false, error: "prompt_too_long", max: @max_prompt_length})
  end

  def query(conn, _params) do
    conn |> put_status(400) |> json(%{ok: false, error: "missing_prompt"})
  end

  # ---------------------------------------------------------------------------
  # POST /api/v1/llm/stream — true SSE
  # ---------------------------------------------------------------------------

  def stream(conn, %{"prompt" => prompt}) when byte_size(prompt) <= @max_prompt_length do
    user_id = get_user_id(conn)

    with :ok <- check_rate_limit(user_id) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> send_chunked(200)

      result = Burble.LLM.stream_query(user_id, prompt, fn text ->
        chunk(conn, "data: #{Jason.encode!(%{text: text})}\n\n")
      end)

      case result do
        :ok ->
          chunk(conn, "data: #{Jason.encode!(%{done: true})}\n\n")
        {:error, reason} ->
          chunk(conn, "data: #{Jason.encode!(%{error: inspect(reason)})}\n\n")
      end

      conn
    else
      {:rate_limited, retry_after} ->
        conn
        |> put_status(429)
        |> put_resp_header("retry-after", to_string(retry_after))
        |> json(%{ok: false, error: "rate_limited", retry_after: retry_after})
    end
  end

  def stream(conn, params), do: query(conn, params)

  # ---------------------------------------------------------------------------
  # GET /api/v1/llm/status
  # ---------------------------------------------------------------------------

  def status(conn, _params) do
    provider = :persistent_term.get({Burble.LLM, :provider}, nil)

    cb_status =
      if function_exported?(Burble.LLM.AnthropicProvider, :circuit_breaker_status, 0) do
        Atom.to_string(Burble.LLM.AnthropicProvider.circuit_breaker_status())
      else
        "unknown"
      end

    json(conn, %{
      available: provider != nil,
      provider: if(provider, do: inspect(provider), else: nil),
      api_key_set: System.get_env("ANTHROPIC_API_KEY") != nil,
      circuit_breaker: cb_status
    })
  end

  # ---------------------------------------------------------------------------
  # Per-user rate limiting (ETS token bucket, keyed by user_id)
  # ---------------------------------------------------------------------------

  @rate_table :burble_llm_rate_limit

  defp check_rate_limit(user_id) do
    ensure_rate_table()
    now = System.monotonic_time(:millisecond)
    key = {:llm_rate, user_id}

    case :ets.lookup(@rate_table, key) do
      [{^key, count, window_start}] when now - window_start < @rate_limit_window_ms ->
        if count >= @rate_limit_max do
          retry_after = div(@rate_limit_window_ms - (now - window_start), 1000) + 1
          {:rate_limited, retry_after}
        else
          :ets.update_counter(@rate_table, key, {2, 1})
          :ok
        end

      _ ->
        :ets.insert(@rate_table, {key, 1, now})
        :ok
    end
  end

  defp ensure_rate_table do
    case :ets.info(@rate_table) do
      :undefined -> :ets.new(@rate_table, [:set, :public, :named_table]); :ok
      _ -> :ok
    end
  end

  defp get_user_id(conn) do
    case conn.assigns[:current_user] do
      %{id: id} -> id
      _ -> to_string(:inet.ntoa(conn.remote_ip))
    end
  end
end
