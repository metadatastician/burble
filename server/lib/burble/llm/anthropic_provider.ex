# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

defmodule Burble.LLM.AnthropicProvider do
  @moduledoc """
  Anthropic Claude API provider for Burble's LLM service.

  Calls the Claude Messages API via Erlang's built-in :httpc (no extra deps).
  Reads ANTHROPIC_API_KEY from environment. Falls back gracefully when unconfigured.

  Failure handling is delegated to `Burble.CircuitBreaker` under the
  registered name `:llm_anthropic` (5 consecutive failures → open for 30s).
  """

  require Logger

  alias Burble.CircuitBreaker

  @api_url ~c"https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @default_model "claude-sonnet-4-6"
  @default_max_tokens 4096
  @request_timeout 60_000

  @cb_name :llm_anthropic

  defp ensure_httpc do
    :inets.start()
    :ssl.start()
    CircuitBreaker.register(@cb_name, failure_threshold: 5, open_duration_ms: 30_000)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def process_query(user_id, prompt) do
    ensure_httpc()

    case api_key() do
      nil -> {:error, :api_key_not_configured}
      key -> CircuitBreaker.with_breaker(@cb_name, fn -> do_query(user_id, prompt, key) end)
    end
  end

  def stream_query(user_id, prompt, callback) do
    ensure_httpc()

    case api_key() do
      nil ->
        {:error, :api_key_not_configured}

      key ->
        CircuitBreaker.with_breaker(@cb_name, fn -> do_stream(user_id, prompt, callback, key) end)
    end
  end

  @doc "Current circuit breaker state: `:closed`, `:half_open`, or `:open`."
  def circuit_breaker_status, do: CircuitBreaker.state(@cb_name)

  @doc "Manually reset the circuit breaker (e.g. after fixing an outage)."
  def reset_circuit_breaker, do: CircuitBreaker.reset(@cb_name)

  # ---------------------------------------------------------------------------
  # HTTP calls
  # ---------------------------------------------------------------------------

  defp do_query(user_id, prompt, key) do
    body =
      Jason.encode!(%{
        model: model(),
        max_tokens: max_tokens(),
        messages: [%{role: "user", content: prompt}],
        system: system_prompt(user_id)
      })

    request = {@api_url, auth_headers(key), ~c"application/json", String.to_charlist(body)}

    case :httpc.request(:post, request, [timeout: @request_timeout, ssl: ssl_opts()], []) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        parse_response(List.to_string(resp_body))

      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        Logger.warning("[LLM/Anthropic] API returned #{status}: #{List.to_string(resp_body)}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        Logger.error("[LLM/Anthropic] HTTP request failed: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  defp do_stream(user_id, prompt, callback, key) do
    body =
      Jason.encode!(%{
        model: model(),
        max_tokens: max_tokens(),
        stream: true,
        messages: [%{role: "user", content: prompt}],
        system: system_prompt(user_id)
      })

    request = {@api_url, auth_headers(key), ~c"application/json", String.to_charlist(body)}

    case :httpc.request(:post, request, [timeout: @request_timeout, ssl: ssl_opts()], []) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        parse_sse_stream(List.to_string(resp_body), callback)

      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        Logger.warning("[LLM/Anthropic] Stream API returned #{status}")
        {:error, {:api_error, status, List.to_string(resp_body)}}

      {:error, reason} ->
        Logger.error("[LLM/Anthropic] Stream HTTP request failed: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  defp auth_headers(key) do
    [
      {~c"content-type", ~c"application/json"},
      {~c"x-api-key", String.to_charlist(key)},
      {~c"anthropic-version", String.to_charlist(@api_version)}
    ]
  end

  # ---------------------------------------------------------------------------
  # Response parsing
  # ---------------------------------------------------------------------------

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, %{"content" => [%{"text" => text} | _]}} ->
        {:ok, text}

      {:ok, %{"error" => %{"message" => msg}}} ->
        {:error, {:api_error, msg}}

      {:ok, other} ->
        Logger.warning("[LLM/Anthropic] Unexpected response shape: #{inspect(other)}")
        {:error, :unexpected_response}

      {:error, _} ->
        {:error, :json_decode_error}
    end
  end

  defp parse_sse_stream(body, callback) do
    body
    |> String.split("\n")
    |> Enum.each(fn line ->
      case line do
        "data: " <> json_str ->
          case Jason.decode(json_str) do
            {:ok, %{"type" => "content_block_delta", "delta" => %{"text" => text}}} ->
              callback.(text)

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Config helpers
  # ---------------------------------------------------------------------------

  defp api_key, do: System.get_env("ANTHROPIC_API_KEY")
  defp model, do: System.get_env("ANTHROPIC_MODEL") || @default_model

  defp max_tokens do
    case System.get_env("ANTHROPIC_MAX_TOKENS") do
      nil -> @default_max_tokens
      val -> String.to_integer(val)
    end
  end

  defp system_prompt(user_id) do
    "You are a helpful AI assistant integrated into Burble, a P2P voice and collaboration platform. " <>
      "You are responding to user #{user_id}. Be concise, technical when appropriate, and helpful. " <>
      "If the user asks about Burble features, you can mention voice chat, AI bridge, E2EE, and WebRTC."
  end

  defp ssl_opts do
    [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 3]
  end
end
