# SPDX-License-Identifier: MPL-2.0
#
# Burble.Network.TurnCredentials — time-limited TURN credential generator.
#
# Implements the TURN REST API credential pattern (RFC 5766 §15 / draft-uberti):
#   username = "<unix_expiry>:<user_id>"
#   password = base64(hmac_sha1(TURN_SECRET, username))
#
# Short-lived credentials (24 h) mean a stolen token is worthless after expiry.
# coturn verifies the HMAC signature server-side without needing to look up users.

defmodule Burble.Network.TurnCredentials do
  @ttl_seconds 86_400

  @doc """
  Returns an ICE server list for the given user.

  Includes STUN always. Adds TURN/TURNS with time-limited credentials when
  TURN_SECRET is configured. Falls back to public Google STUN if no STUN_URL
  is set (not recommended for production).
  """
  def ice_servers(user_id \\ "anonymous") do
    stun_url = Application.get_env(:burble, :stun_url, "stun:stun.l.google.com:19302")
    turn_url = Application.get_env(:burble, :turn_url)
    turns_url = Application.get_env(:burble, :turns_url)
    secret = Application.get_env(:burble, :turn_secret)

    base = [%{urls: stun_url}]

    if turn_url && secret && secret != "" do
      {username, credential} = generate_credentials(user_id, secret)

      [turn_url, turns_url]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&%{urls: &1, username: username, credential: credential})
      |> then(&(base ++ &1))
    else
      base
    end
  end

  @doc "Generate an HMAC-SHA1 TURN credential pair for the given user."
  def generate_credentials(user_id, secret) do
    expiry = System.system_time(:second) + @ttl_seconds
    username = "#{expiry}:#{user_id}"
    credential = :crypto.mac(:hmac, :sha, secret, username) |> Base.encode64()
    {username, credential}
  end
end
