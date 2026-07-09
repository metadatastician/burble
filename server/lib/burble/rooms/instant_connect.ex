# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Burble.Rooms.InstantConnect — Link/QR/code-based instant voice connections.
#
# Three ways to instantly connect:
#   1. Link   — https://burble.local/join/ABCD1234 (shareable URL)
#   2. QR     — encodes the join link as a QR code (scan with phone)
#   3. Code   — 8-char alphanumeric code typed manually (e.g. ABCD1234)
#
# Flow:
#   1. User A generates a connect token (link/QR/code)
#   2. User B opens link / scans QR / enters code
#   3. Both users confirm the connection (mutual consent via Avow)
#   4. A temporary voice room is created (or B joins A's existing room)
#   5. Either user can invite more people (generates new tokens)
#   6. Users can split back to original groups or form new ones
#
# Tokens expire after 5 minutes by default. Used tokens are consumed
# (one-time use unless configured as multi-use for group invites).
#
# Integration:
#   - IDApTIK: two gamers connect, then join a larger squad
#   - PanLL: instant huddle from workspace panel
#   - Standalone: share a link to start a voice call

defmodule Burble.Rooms.InstantConnect do
  @moduledoc """
  Instant voice connection via shareable links, QR codes, and short codes.

  ## Usage

      # Generate a connect token.
      {:ok, token} = InstantConnect.create_token(user_id, opts)

      # Get the join URL.
      url = InstantConnect.token_to_url(token)

      # Get the short code.
      code = token.code  # e.g. "ABCD1234"

      # Redeem a token (other user joins).
      {:ok, room_id} = InstantConnect.redeem(token_code, joining_user_id)
  """

  use GenServer

  require Logger

  alias Burble.Rooms.RoomManager

  @default_ttl_seconds 300  # 5 minutes.
  @code_length 8
  @code_alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # No I/O/0/1 (ambiguity).

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type connect_token :: %{
          code: String.t(),
          creator_id: String.t(),
          creator_name: String.t(),
          room_id: String.t() | nil,
          group_invite: boolean(),
          max_uses: pos_integer(),
          uses: non_neg_integer(),
          requires_confirmation: boolean(),
          expires_at: DateTime.t(),
          created_at: DateTime.t(),
          # Pending confirmations: joining_user_id => true.
          pending_confirmations: map()
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, opts ++ [name: __MODULE__])
  end

  @doc """
  Create a new connect token.

  ## Options
    - `:room_id` — existing room to join (nil = create new room on redeem)
    - `:group_invite` — allow multiple people to use this token (default: false)
    - `:max_uses` — maximum number of redemptions (default: 1, or 50 for group)
    - `:ttl_seconds` — time-to-live in seconds (default: 300 = 5 min)
    - `:requires_confirmation` — both sides must confirm (default: true)
    - `:creator_name` — display name of the creator
  """
  def create_token(creator_id, opts \\ []) do
    GenServer.call(__MODULE__, {:create, creator_id, opts})
  end

  @doc """
  Convert a token to a shareable URL.
  Base URL is configurable via BURBLE_BASE_URL env var.
  """
  def token_to_url(%{code: code}) do
    base = System.get_env("BURBLE_BASE_URL", "http://localhost:6473")
    "#{base}/join/#{code}"
  end

  @doc """
  Convert a token to a QR code data URI (SVG).
  Uses a simple QR encoding — the client renders it.
  Returns the join URL (client-side QR generation is better for styling).
  """
  def token_to_qr_data(%{code: code}) do
    url = token_to_url(%{code: code})
    %{url: url, code: code}
  end

  @doc """
  Look up a token by its short code.
  Returns `{:ok, token}` or `{:error, :not_found | :expired | :exhausted}`.
  """
  def lookup(code) do
    GenServer.call(__MODULE__, {:lookup, String.upcase(code)})
  end

  @doc """
  Redeem a token — the joining user connects.

  If `requires_confirmation` is true, this puts the join in pending state.
  The creator must then call `confirm/2` to complete the connection.
  If false, the user is immediately connected.

  Returns `{:ok, room_id}` or `{:pending, token}` or `{:error, reason}`.
  """
  def redeem(code, joining_user_id, joining_user_name \\ "Guest") do
    GenServer.call(__MODULE__, {:redeem, String.upcase(code), joining_user_id, joining_user_name})
  end

  @doc """
  Confirm a pending connection (creator approves the joiner).
  """
  def confirm(code, joining_user_id) do
    GenServer.call(__MODULE__, {:confirm, String.upcase(code), joining_user_id})
  end

  @doc """
  Reject a pending connection.
  """
  def reject(code, joining_user_id) do
    GenServer.call(__MODULE__, {:reject, String.upcase(code), joining_user_id})
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Periodically clean expired tokens.
    :timer.send_interval(60_000, :cleanup_expired)
    {:ok, %{tokens: %{}}}
  end

  @impl true
  def handle_call({:create, creator_id, opts}, _from, state) do
    group_invite = Keyword.get(opts, :group_invite, false)

    token = %{
      code: generate_code(),
      creator_id: creator_id,
      creator_name: Keyword.get(opts, :creator_name, "Unknown"),
      room_id: Keyword.get(opts, :room_id),
      group_invite: group_invite,
      max_uses: Keyword.get(opts, :max_uses, if(group_invite, do: 50, else: 1)),
      uses: 0,
      requires_confirmation: Keyword.get(opts, :requires_confirmation, true),
      expires_at: DateTime.add(DateTime.utc_now(), Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)),
      created_at: DateTime.utc_now(),
      pending_confirmations: %{}
    }

    new_state = put_in(state, [:tokens, token.code], token)

    Logger.info("[InstantConnect] Token #{token.code} created by #{creator_id}" <>
      if(group_invite, do: " (group, max #{token.max_uses})", else: " (1:1)"))

    {:reply, {:ok, token}, new_state}
  end

  @impl true
  def handle_call({:lookup, code}, _from, state) do
    case Map.get(state.tokens, code) do
      nil ->
        {:reply, {:error, :not_found}, state}

      token ->
        cond do
          DateTime.compare(DateTime.utc_now(), token.expires_at) == :gt ->
            {:reply, {:error, :expired}, state}

          token.uses >= token.max_uses ->
            {:reply, {:error, :exhausted}, state}

          true ->
            {:reply, {:ok, token}, state}
        end
    end
  end

  @impl true
  def handle_call({:redeem, code, joining_user_id, joining_user_name}, _from, state) do
    case Map.get(state.tokens, code) do
      nil ->
        {:reply, {:error, :not_found}, state}

      token ->
        cond do
          DateTime.compare(DateTime.utc_now(), token.expires_at) == :gt ->
            {:reply, {:error, :expired}, state}

          token.uses >= token.max_uses ->
            {:reply, {:error, :exhausted}, state}

          token.creator_id == joining_user_id ->
            {:reply, {:error, :cannot_join_own_token}, state}

          true ->
            if token.requires_confirmation do
              # Put in pending state — creator must confirm.
              updated_token = %{token |
                pending_confirmations: Map.put(token.pending_confirmations, joining_user_id, %{
                  name: joining_user_name,
                  requested_at: DateTime.utc_now()
                })
              }
              new_state = put_in(state, [:tokens, code], updated_token)
              {:reply, {:pending, updated_token}, new_state}
            else
              # Immediate connection.
              case connect_user(token, joining_user_id, joining_user_name) do
                {:ok, room_id, updated_token} ->
                  new_state = put_in(state, [:tokens, code], updated_token)
                  {:reply, {:ok, room_id}, new_state}

                {:error, reason} ->
                  {:reply, {:error, reason}, state}
              end
            end
        end
    end
  end

  @impl true
  def handle_call({:confirm, code, joining_user_id}, _from, state) do
    case Map.get(state.tokens, code) do
      nil ->
        {:reply, {:error, :not_found}, state}

      token ->
        if Map.has_key?(token.pending_confirmations, joining_user_id) do
          pending_info = Map.get(token.pending_confirmations, joining_user_id)
          joining_name = Map.get(pending_info, :name, "Guest")

          case connect_user(token, joining_user_id, joining_name) do
            {:ok, room_id, updated_token} ->
              # Remove from pending.
              final_token = %{updated_token |
                pending_confirmations: Map.delete(updated_token.pending_confirmations, joining_user_id)
              }
              new_state = put_in(state, [:tokens, code], final_token)
              {:reply, {:ok, room_id}, new_state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          {:reply, {:error, :no_pending_request}, state}
        end
    end
  end

  @impl true
  def handle_call({:reject, code, joining_user_id}, _from, state) do
    case Map.get(state.tokens, code) do
      nil ->
        {:reply, {:error, :not_found}, state}

      token ->
        updated = %{token |
          pending_confirmations: Map.delete(token.pending_confirmations, joining_user_id)
        }
        new_state = put_in(state, [:tokens, code], updated)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    now = DateTime.utc_now()

    cleaned =
      state.tokens
      |> Enum.reject(fn {_code, token} ->
        DateTime.compare(now, token.expires_at) == :gt
      end)
      |> Map.new()

    removed = map_size(state.tokens) - map_size(cleaned)
    if removed > 0, do: Logger.debug("[InstantConnect] Cleaned #{removed} expired tokens")

    {:noreply, %{state | tokens: cleaned}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp generate_code do
    alphabet = @code_alphabet

    1..@code_length
    |> Enum.map(fn _ -> Enum.at(alphabet, :rand.uniform(length(alphabet)) - 1) end)
    |> List.to_string()
  end

  defp connect_user(token, joining_user_id, joining_user_name) do
    room_id =
      if token.room_id do
        token.room_id
      else
        case RoomManager.create_adhoc_room(token.creator_id, token.creator_name) do
          {:ok, room} -> room.id
          _ -> nil
        end
      end

    if room_id do
      case RoomManager.join_room(room_id, joining_user_id, joining_user_name) do
        {:ok, _participant} ->
          updated_token = %{token | uses: token.uses + 1, room_id: room_id}
          Logger.info("[InstantConnect] #{joining_user_id} connected via #{token.code} → room #{room_id}")
          {:ok, room_id, updated_token}

        error ->
          error
      end
    else
      {:error, :room_creation_failed}
    end
  end
end
