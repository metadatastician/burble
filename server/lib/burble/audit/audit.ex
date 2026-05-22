# SPDX-License-Identifier: MPL-2.0
#
# Burble.Audit — Audit logging for moderation and admin actions.

defmodule Burble.Audit do
  @moduledoc "Audit log for moderation and admin actions."

  require Logger

  def log(action, actor_id, metadata \\ %{}) do
    entry = %{
      action: action,
      actor_id: actor_id,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }

    Logger.info("[Audit] #{action} by #{actor_id}: #{inspect(metadata)}")
    {:ok, entry}
  end
end
