# SPDX-License-Identifier: MPL-2.0
# Seeds for development — creates a test user via VeriSimDB.
#
# Set DEV_USER_PASSWORD in your environment to override the default.

alias Burble.Auth

dev_password = System.get_env("DEV_USER_PASSWORD", Base.encode64(:crypto.strong_rand_bytes(12)))

case Auth.register_user(%{
  email: "dev@burble.local",
  display_name: "Dev User",
  password: dev_password
}) do
  {:ok, _user} -> IO.puts("Created dev user: dev@burble.local (password: #{dev_password})")
  {:error, _} -> IO.puts("Dev user may already exist (check VeriSimDB)")
end
