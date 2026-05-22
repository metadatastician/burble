# SPDX-License-Identifier: MPL-2.0
#
# mix bolt — send a Burble Bolt from the command line (dev/test).
#
# Usage:
#   mix bolt 192.168.1.100
#   mix bolt 192.168.1.100/aa:bb:cc:dd:ee:ff
#   mix bolt fe80::1
#   mix bolt user@example.com
#   mix bolt --broadcast

defmodule Mix.Tasks.Bolt do
  use Mix.Task

  @shortdoc "Send a Burble Bolt magic packet to a target"

  @moduledoc """
  Send a Burble Bolt to an IPv4, IPv6, or domain target.

      mix bolt 192.168.1.100
      mix bolt 192.168.1.100/aa:bb:cc:dd:ee:ff
      mix bolt fe80::1
      mix bolt user@example.com
      mix bolt --broadcast

  Options:
    --name "Alice"   Display name shown in the recipient's notification
    --ack            Request an acknowledgement bolt back
    --no-wol         Skip sending to WoL port 9
  """

  @impl Mix.Task
  def run(args) do
    # Ensure Jason is available (used by Packet.encode)
    Application.ensure_all_started(:jason)

    Burble.Bolt.cli_main(args)
  end
end
