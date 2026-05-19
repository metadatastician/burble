# SPDX-License-Identifier: PMPL-1.0-or-later
#
# Burble.Store — VeriSimDB-backed persistent store.
#
# Replaces Ecto/PostgreSQL with VeriSimDB octad entities. Each user account
# is stored as a VeriSimDB octad with document modality (structured fields)
# and provenance modality (login history, audit trail).
#
# The Store is a GenServer that holds the VeriSimClient connection and
# provides domain-specific CRUD operations. It starts as part of the
# OTP supervision tree before any module that needs persistence.
#
# Dogfooding: Burble is the first hyperpolymath project to run on VeriSimDB
# as its primary data store. Exercises the Elixir client SDK, REST API,
# and document modality in a real production workload.

defmodule Burble.Store do
  @moduledoc """
  VeriSimDB-backed persistent store for Burble.

  Provides user account CRUD, token storage, and audit logging via
  VeriSimDB octad entities. Each domain entity maps to an octad with
  appropriate modalities populated.

  ## Entity mapping

  | Domain entity | Octad name prefix | Modalities used                    |
  |---------------|-------------------|------------------------------------|
  | User account  | `user:<email>`    | document (fields), provenance (audit) |
  | Invite token  | `invite:<token>`  | document (fields), temporal (expiry)  |
  | Magic link    | `magic:<token>`   | document (fields), temporal (expiry)  |

  ## Configuration

  In `config.exs`:

      config :burble, Burble.Store,
        url: "http://localhost:8080",
        auth: :none,
        timeout: 30_000
  """

  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Start the Store GenServer, linking to the supervision tree."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new user account in VeriSimDB.

  Stores the user as an octad with document modality containing the
  structured fields and provenance modality recording the creation event.

  Returns `{:ok, user_map}` or `{:error, reason}`.
  """
  @spec create_user(map()) :: {:ok, map()} | {:error, term()}
  def create_user(attrs) do
    GenServer.call(__MODULE__, {:create_user, attrs})
  end

  @doc """
  Look up a user by email address.

  Uses VeriSimDB text search on the octad name (which encodes the email).
  Returns `{:ok, user_map}` or `{:error, :not_found}`.
  """
  @spec get_user_by_email(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_user_by_email(email) do
    GenServer.call(__MODULE__, {:get_user_by_email, email})
  end

  @doc """
  Look up a user by their VeriSimDB octad ID.

  Returns `{:ok, user_map}` or `{:error, :not_found}`.
  """
  @spec get_user(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_user(id) do
    GenServer.call(__MODULE__, {:get_user, id})
  end

  @doc """
  Update a user's fields (partial merge).

  Returns `{:ok, user_map}` or `{:error, reason}`.
  """
  @spec update_user(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_user(id, attrs) do
    GenServer.call(__MODULE__, {:update_user, id, attrs})
  end

  @doc """
  Record a provenance event against a user (login, password change, etc.).
  """
  @spec record_user_event(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def record_user_event(user_id, event_type, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:record_user_event, user_id, event_type, metadata})
  end

  @doc """
  Store a magic link token with a 15-minute expiry.

  Uses VeriSimDB temporal modality to encode the expiry timestamp,
  and document modality for the email association.

  Returns `{:ok, token}` or `{:error, reason}`.
  """
  @spec store_magic_link(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def store_magic_link(token, email) do
    GenServer.call(__MODULE__, {:store_magic_link, token, email})
  end

  @doc """
  Validate and consume a magic link token.

  Returns `{:ok, email}` if the token is valid and not expired,
  or `{:error, :invalid_token}` / `{:error, :expired}`.
  """
  @spec consume_magic_link(String.t()) :: {:ok, String.t()} | {:error, :invalid_token | :expired}
  def consume_magic_link(token) do
    GenServer.call(__MODULE__, {:consume_magic_link, token})
  end

  @doc """
  Store an invite token with metadata and expiry.

  Uses VeriSimDB temporal modality for auto-expiry tracking and
  document modality for invite configuration (max_uses, server_id).

  Returns `{:ok, invite_map}` or `{:error, reason}`.
  """
  @spec store_invite(map()) :: {:ok, map()} | {:error, term()}
  def store_invite(invite) do
    GenServer.call(__MODULE__, {:store_invite, invite})
  end

  @doc """
  Look up and validate an invite token.

  Returns `{:ok, invite_map}` if valid (not expired, uses remaining),
  or `{:error, :invalid_token}` / `{:error, :expired}` / `{:error, :exhausted}`.
  """
  @spec consume_invite(String.t()) ::
          {:ok, map()} | {:error, :invalid_token | :expired | :exhausted}
  def consume_invite(token) do
    GenServer.call(__MODULE__, {:consume_invite, token})
  end

  @doc """
  Save a room configuration to VeriSimDB.

  Stored as an octad with document modality (room settings) and
  provenance modality (config change history).
  """
  @spec save_room_config(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def save_room_config(room_id, config) do
    GenServer.call(__MODULE__, {:save_room_config, room_id, config})
  end

  @doc """
  Load a room configuration from VeriSimDB.

  Returns `{:ok, config_map}` or `{:error, :not_found}`.
  """
  @spec load_room_config(String.t()) :: {:ok, map()} | {:error, :not_found}
  def load_room_config(room_id) do
    GenServer.call(__MODULE__, {:load_room_config, room_id})
  end

  @doc """
  Save a server/guild configuration to VeriSimDB.

  Stored as an octad with document modality (server settings, roles,
  permissions) and provenance modality (admin action history).
  """
  @spec save_server_config(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def save_server_config(server_id, config) do
    GenServer.call(__MODULE__, {:save_server_config, server_id, config})
  end

  @doc """
  Load a server/guild configuration from VeriSimDB.
  """
  @spec load_server_config(String.t()) :: {:ok, map()} | {:error, :not_found}
  def load_server_config(server_id) do
    GenServer.call(__MODULE__, {:load_server_config, server_id})
  end

  @doc """
  Check if the VeriSimDB connection is healthy.
  """
  @spec health() :: {:ok, boolean()} | {:error, term()}
  def health do
    GenServer.call(__MODULE__, :health)
  end

  @doc """
  List octads whose name matches `prefix` (e.g. `"user:"`, `"room_config:"`).

  Used by `Burble.Store.Backup` to enumerate entities for export. Returns
  raw octad maps so the caller can preserve every modality.
  """
  @spec list_by_prefix(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_by_prefix(prefix, limit \\ 10_000) do
    GenServer.call(__MODULE__, {:list_by_prefix, prefix, limit}, 60_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  # Maximum number of VeriSimDB health-check attempts before giving up at boot.
  # Delays follow exponential backoff: 1s, 2s, 4s, 8s, 16s (total up to ~31s).
  @health_check_max_attempts 5

  @impl true
  def init(_opts) do
    config = Application.get_env(:burble, __MODULE__, [])
    url = Keyword.get(config, :url, "http://localhost:8080")
    auth = Keyword.get(config, :auth, :none)
    timeout = Keyword.get(config, :timeout, 30_000)
    offline_ok = Keyword.get(config, :offline_ok, false)

    case VeriSimClient.new(url, auth: auth, timeout: timeout) do
      {:ok, client} ->
        Logger.info("[Burble.Store] Connected to VeriSimDB at #{url}")

        # Wait for VeriSimDB to be reachable before running migrations.
        # The server may start before VeriSimDB's DNS entry propagates in the
        # container bridge network — retry with exponential backoff to absorb
        # the startup race.
        {attempts, base_delay} =
          if offline_ok, do: {1, 200}, else: {@health_check_max_attempts, 1_000}

        case await_verisimdb(client, attempts, base_delay) do
          :ok ->
            # Run pending VeriSimDB migrations (idempotent setup scripts).
            # Migration failure is fatal: the store must not start with an
            # uninitialised schema — callers would silently operate against
            # a broken data layer.
            case Burble.Store.Migrator.run(client) do
              :ok ->
                {:ok, %{client: client}}

              {:error, reason} ->
                Logger.error("[Burble.Store] Migration failed: #{inspect(reason)}")
                {:stop, {:migration_failed, reason}}
            end

          {:error, :unreachable} when offline_ok ->
            Logger.warning(
              "[Burble.Store] VeriSimDB at #{url} unreachable — starting in " <>
                "degraded offline mode (offline_ok: true); DB-backed calls " <>
                "return errors until it is available"
            )

            {:ok, %{client: client, offline: true}}

          {:error, :unreachable} ->
            Logger.error(
              "[Burble.Store] VeriSimDB at #{url} did not become healthy after " <>
                "#{@health_check_max_attempts} attempts — refusing to start"
            )

            {:stop, :verisimdb_unreachable}
        end

      {:error, reason} ->
        Logger.error("[Burble.Store] Failed to connect to VeriSimDB: #{inspect(reason)}")
        {:stop, {:verisimdb_connection_failed, reason}}
    end
  end

  # Poll VeriSimDB health endpoint with exponential backoff.
  # Returns :ok when the endpoint responds, {:error, :unreachable} when all
  # attempts are exhausted.
  defp await_verisimdb(_client, 0, _delay_ms) do
    {:error, :unreachable}
  end

  defp await_verisimdb(client, attempts_left, delay_ms) do
    case VeriSimClient.health(client) do
      {:ok, true} ->
        :ok

      other ->
        Logger.warning(
          "[Burble.Store] VeriSimDB not ready (#{inspect(other)}); " <>
            "retrying in #{delay_ms}ms (#{attempts_left - 1} attempt(s) remaining)"
        )

        Process.sleep(delay_ms)
        # Exponential backoff: double the delay each attempt, capped at 16s.
        next_delay = min(delay_ms * 2, 16_000)
        await_verisimdb(client, attempts_left - 1, next_delay)
    end
  end

  @impl true
  def handle_call({:create_user, attrs}, _from, %{client: client} = state) do
    email = Map.get(attrs, :email) || Map.get(attrs, "email")
    display_name = Map.get(attrs, :display_name) || Map.get(attrs, "display_name")
    password_hash = Map.get(attrs, :password_hash) || Map.get(attrs, "password_hash")
    is_admin = Map.get(attrs, :is_admin, false)
    mfa_enabled = Map.get(attrs, :mfa_enabled, false)

    octad_input = %{
      name: "user:#{String.downcase(email)}",
      description: "Burble user account: #{display_name}",
      metadata: %{entity_type: "burble_user"},
      document: %{
        content:
          Jason.encode!(%{
            email: String.downcase(email),
            display_name: display_name,
            password_hash: password_hash,
            is_admin: is_admin,
            mfa_enabled: mfa_enabled,
            mfa_secret: nil,
            last_seen_at: nil
          }),
        content_type: "application/json",
        language: "en",
        metadata: %{schema_version: 1}
      },
      provenance: %{
        event_type: "account_created",
        agent: "burble_auth",
        description: "User account registered",
        metadata: %{ip: "unknown"}
      }
    }

    case VeriSimClient.Octad.create(client, octad_input) do
      {:ok, octad} ->
        user = octad_to_user(octad)
        {:reply, {:ok, user}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_user_by_email, email}, _from, %{client: client} = state) do
    # Search by octad name which encodes the email.
    normalised = String.downcase(email)
    search_name = "user:#{normalised}"

    case VeriSimClient.Search.text(client, search_name, limit: 1) do
      {:ok, results} when is_list(results) ->
        case Enum.find(results, fn r ->
               get_in(r, ["name"]) == search_name || get_in(r, [:name]) == search_name
             end) do
          nil -> {:reply, {:error, :not_found}, state}
          octad -> {:reply, {:ok, octad_to_user(octad)}, state}
        end

      {:ok, %{"data" => data}} when is_list(data) ->
        case Enum.find(data, fn r ->
               get_in(r, ["name"]) == search_name || get_in(r, [:name]) == search_name
             end) do
          nil -> {:reply, {:error, :not_found}, state}
          octad -> {:reply, {:ok, octad_to_user(octad)}, state}
        end

      {:ok, _} ->
        {:reply, {:error, :not_found}, state}

      {:error, reason} ->
        Logger.warning("[Burble.Store] User lookup failed: #{inspect(reason)}")
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_user, id}, _from, %{client: client} = state) do
    case VeriSimClient.Octad.get(client, id) do
      {:ok, octad} -> {:reply, {:ok, octad_to_user(octad)}, state}
      {:error, {:not_found, _}} -> {:reply, {:error, :not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:update_user, id, attrs}, _from, %{client: client} = state) do
    # Fetch current document content, merge, and update.
    case VeriSimClient.Octad.get(client, id) do
      {:ok, octad} ->
        current_doc = extract_document_fields(octad)
        merged = Map.merge(current_doc, stringify_keys(attrs))

        update_input = %{
          document: %{
            content: Jason.encode!(merged),
            content_type: "application/json",
            metadata: %{schema_version: 1}
          }
        }

        case VeriSimClient.Octad.update(client, id, update_input) do
          {:ok, updated} -> {:reply, {:ok, octad_to_user(updated)}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:store_magic_link, token, email}, _from, %{client: client} = state) do
    expires_at = DateTime.add(DateTime.utc_now(), 15 * 60, :second)

    octad_input = %{
      name: "magic:#{token}",
      description: "Magic link for #{email}",
      metadata: %{entity_type: "burble_magic_link"},
      document: %{
        content: Jason.encode!(%{email: String.downcase(email), consumed: false}),
        content_type: "application/json"
      },
      temporal: %{
        timestamp: DateTime.to_iso8601(expires_at),
        duration_ms: 15 * 60 * 1000,
        metadata: %{type: "expiry"}
      }
    }

    case VeriSimClient.Octad.create(client, octad_input) do
      {:ok, _octad} -> {:reply, {:ok, token}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:consume_magic_link, token}, _from, %{client: client} = state) do
    search_name = "magic:#{token}"

    case VeriSimClient.Search.text(client, search_name, limit: 1) do
      {:ok, results} when is_list(results) ->
        case find_by_name(results, search_name) do
          nil ->
            {:reply, {:error, :invalid_token}, state}

          octad ->
            fields = extract_document_fields(octad)
            temporal = get_in(octad, ["temporal"]) || get_in(octad, [:temporal]) || %{}
            expires_str = temporal["timestamp"] || temporal[:timestamp]

            cond do
              fields["consumed"] == true ->
                {:reply, {:error, :invalid_token}, state}

              expired?(expires_str) ->
                {:reply, {:error, :expired}, state}

              true ->
                # Mark as consumed.
                octad_id = get_in(octad, ["id"]) || get_in(octad, [:id])
                mark_consumed(client, octad_id, fields)
                {:reply, {:ok, fields["email"]}, state}
            end
        end

      {:ok, %{"data" => data}} when is_list(data) ->
        case find_by_name(data, search_name) do
          nil ->
            {:reply, {:error, :invalid_token}, state}

          octad ->
            fields = extract_document_fields(octad)
            temporal = get_in(octad, ["temporal"]) || get_in(octad, [:temporal]) || %{}
            expires_str = temporal["timestamp"] || temporal[:timestamp]

            cond do
              fields["consumed"] == true ->
                {:reply, {:error, :invalid_token}, state}

              expired?(expires_str) ->
                {:reply, {:error, :expired}, state}

              true ->
                octad_id = get_in(octad, ["id"]) || get_in(octad, [:id])
                mark_consumed(client, octad_id, fields)
                {:reply, {:ok, fields["email"]}, state}
            end
        end

      _ ->
        {:reply, {:error, :invalid_token}, state}
    end
  end

  @impl true
  def handle_call({:store_invite, invite}, _from, %{client: client} = state) do
    token = invite.token || invite["token"]
    server_id = invite.server_id || invite["server_id"]
    max_uses = invite.max_uses || invite["max_uses"] || 1
    expires_at = invite.expires_at || invite["expires_at"]

    octad_input = %{
      name: "invite:#{token}",
      description: "Invite token for server #{server_id}",
      metadata: %{entity_type: "burble_invite"},
      document: %{
        content:
          Jason.encode!(%{
            token: token,
            server_id: server_id,
            max_uses: max_uses,
            uses: 0
          }),
        content_type: "application/json"
      },
      temporal: %{
        timestamp: DateTime.to_iso8601(expires_at),
        metadata: %{type: "expiry"}
      }
    }

    case VeriSimClient.Octad.create(client, octad_input) do
      {:ok, _octad} -> {:reply, {:ok, invite}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:consume_invite, token}, _from, %{client: client} = state) do
    search_name = "invite:#{token}"

    case VeriSimClient.Search.text(client, search_name, limit: 1) do
      {:ok, results} when is_list(results) ->
        handle_invite_result(find_by_name(results, search_name), client, state)

      {:ok, %{"data" => data}} when is_list(data) ->
        handle_invite_result(find_by_name(data, search_name), client, state)

      _ ->
        {:reply, {:error, :invalid_token}, state}
    end
  end

  @impl true
  def handle_call({:save_room_config, room_id, config}, _from, %{client: client} = state) do
    octad_input = %{
      name: "room_config:#{room_id}",
      description: "Room configuration for #{room_id}",
      metadata: %{entity_type: "burble_room_config"},
      document: %{
        content: Jason.encode!(config),
        content_type: "application/json"
      },
      provenance: %{
        event_type: "config_updated",
        agent: "burble_admin",
        description: "Room config saved"
      }
    }

    # Try update first (if exists), else create.
    case find_by_prefix(client, "room_config:#{room_id}") do
      {:ok, octad} ->
        id = get_in(octad, ["id"]) || get_in(octad, [:id])

        case VeriSimClient.Octad.update(client, id, octad_input) do
          {:ok, updated} -> {:reply, {:ok, extract_document_fields(updated)}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      :not_found ->
        case VeriSimClient.Octad.create(client, octad_input) do
          {:ok, created} -> {:reply, {:ok, extract_document_fields(created)}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:load_room_config, room_id}, _from, %{client: client} = state) do
    case find_by_prefix(client, "room_config:#{room_id}") do
      {:ok, octad} -> {:reply, {:ok, extract_document_fields(octad)}, state}
      :not_found -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:save_server_config, server_id, config}, _from, %{client: client} = state) do
    octad_input = %{
      name: "server_config:#{server_id}",
      description: "Server configuration for #{server_id}",
      metadata: %{entity_type: "burble_server_config"},
      document: %{
        content: Jason.encode!(config),
        content_type: "application/json"
      },
      provenance: %{
        event_type: "config_updated",
        agent: "burble_admin",
        description: "Server config saved"
      }
    }

    case find_by_prefix(client, "server_config:#{server_id}") do
      {:ok, octad} ->
        id = get_in(octad, ["id"]) || get_in(octad, [:id])

        case VeriSimClient.Octad.update(client, id, octad_input) do
          {:ok, updated} -> {:reply, {:ok, extract_document_fields(updated)}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      :not_found ->
        case VeriSimClient.Octad.create(client, octad_input) do
          {:ok, created} -> {:reply, {:ok, extract_document_fields(created)}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:load_server_config, server_id}, _from, %{client: client} = state) do
    case find_by_prefix(client, "server_config:#{server_id}") do
      {:ok, octad} -> {:reply, {:ok, extract_document_fields(octad)}, state}
      :not_found -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:health, _from, %{client: client} = state) do
    result = VeriSimClient.health(client)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_by_prefix, prefix, limit}, _from, %{client: client} = state) do
    result =
      case VeriSimClient.Search.text(client, prefix, limit: limit) do
        {:ok, results} when is_list(results) ->
          {:ok, Enum.filter(results, &name_starts_with?(&1, prefix))}

        {:ok, %{"data" => data}} when is_list(data) ->
          {:ok, Enum.filter(data, &name_starts_with?(&1, prefix))}

        {:ok, _} ->
          {:ok, []}

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:record_user_event, user_id, event_type, metadata}, %{client: client} = state) do
    update_input = %{
      provenance: %{
        event_type: event_type,
        agent: "burble_auth",
        description: "#{event_type} for user #{user_id}",
        metadata: metadata
      }
    }

    case VeriSimClient.Octad.update(client, user_id, update_input) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Burble.Store] Failed to record event: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Extract user fields from a VeriSimDB octad response.
  # The document modality content is a JSON string containing the user fields.
  defp octad_to_user(octad) do
    fields = extract_document_fields(octad)
    id = get_in(octad, ["id"]) || get_in(octad, [:id])
    created_at = get_in(octad, ["created_at"]) || get_in(octad, [:created_at])
    modified_at = get_in(octad, ["modified_at"]) || get_in(octad, [:modified_at])

    %{
      id: id,
      email: fields["email"],
      display_name: fields["display_name"],
      password_hash: fields["password_hash"],
      is_admin: fields["is_admin"] || false,
      mfa_enabled: fields["mfa_enabled"] || false,
      mfa_secret: fields["mfa_secret"],
      last_seen_at: fields["last_seen_at"],
      inserted_at: created_at,
      updated_at: modified_at
    }
  end

  # Parse the document modality content (JSON string) into a map.
  defp extract_document_fields(octad) do
    doc = get_in(octad, ["document"]) || get_in(octad, [:document]) || %{}
    content = doc["content"] || doc[:content] || "{}"

    case content do
      c when is_binary(c) ->
        case Jason.decode(c) do
          {:ok, parsed} -> parsed
          {:error, _} -> %{}
        end

      c when is_map(c) ->
        # Already decoded by Req/Jason.
        c

      _ ->
        %{}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Find an octad by name prefix via VeriSimDB text search.
  defp find_by_prefix(client, name) do
    case VeriSimClient.Search.text(client, name, limit: 1) do
      {:ok, results} when is_list(results) ->
        case find_by_name(results, name) do
          nil -> :not_found
          octad -> {:ok, octad}
        end

      {:ok, %{"data" => data}} when is_list(data) ->
        case find_by_name(data, name) do
          nil -> :not_found
          octad -> {:ok, octad}
        end

      _ ->
        :not_found
    end
  end

  # Find an octad in search results by exact name match.
  defp find_by_name(results, name) do
    Enum.find(results, fn r ->
      get_in(r, ["name"]) == name || get_in(r, [:name]) == name
    end)
  end

  defp name_starts_with?(octad, prefix) do
    name = get_in(octad, ["name"]) || get_in(octad, [:name]) || ""
    is_binary(name) and String.starts_with?(name, prefix)
  end

  # Check if an ISO 8601 timestamp is in the past.
  defp expired?(nil), do: true

  defp expired?(timestamp_str) when is_binary(timestamp_str) do
    case DateTime.from_iso8601(timestamp_str) do
      {:ok, expires_at, _offset} -> DateTime.compare(DateTime.utc_now(), expires_at) == :gt
      _ -> true
    end
  end

  defp expired?(_), do: true

  # Mark a magic link octad as consumed by updating its document content.
  defp mark_consumed(client, octad_id, fields) do
    update_input = %{
      document: %{
        content: Jason.encode!(Map.put(fields, "consumed", true)),
        content_type: "application/json"
      }
    }

    VeriSimClient.Octad.update(client, octad_id, update_input)
  end

  # Handle invite token validation and use-count increment.
  defp handle_invite_result(nil, _client, state) do
    {:reply, {:error, :invalid_token}, state}
  end

  defp handle_invite_result(octad, client, state) do
    fields = extract_document_fields(octad)
    temporal = get_in(octad, ["temporal"]) || get_in(octad, [:temporal]) || %{}
    expires_str = temporal["timestamp"] || temporal[:timestamp]
    uses = fields["uses"] || 0
    max_uses = fields["max_uses"] || 1

    cond do
      expired?(expires_str) ->
        {:reply, {:error, :expired}, state}

      uses >= max_uses ->
        {:reply, {:error, :exhausted}, state}

      true ->
        # Increment use count.
        octad_id = get_in(octad, ["id"]) || get_in(octad, [:id])
        updated_fields = Map.put(fields, "uses", uses + 1)

        update_input = %{
          document: %{
            content: Jason.encode!(updated_fields),
            content_type: "application/json"
          }
        }

        VeriSimClient.Octad.update(client, octad_id, update_input)

        invite = %{
          token: fields["token"],
          server_id: fields["server_id"],
          max_uses: max_uses,
          uses: uses + 1
        }

        {:reply, {:ok, invite}, state}
    end
  end
end
