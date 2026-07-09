# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Mix.Tasks.Burble.Groove.Manifest — regenerate the static groove manifest.
#
# The live module attribute `Burble.Groove.@manifest` is canonical; the static
# file at the repo root (.well-known/groove/manifest.json) is generated output
# probed by groove-aware systems before the server is up. Run this task after
# any manifest change and commit the result — CI asserts byte-identity between
# the file and the live manifest (see Burble.GrooveTest).
#
# Usage:
#   mix burble.groove.manifest

defmodule Mix.Tasks.Burble.Groove.Manifest do
  @moduledoc """
  Regenerate the repo-root `.well-known/groove/manifest.json` from the live
  `Burble.Groove` manifest.

  Writes `Jason.encode!(manifest, pretty: true)` plus a trailing newline.
  The static file is generated output — never edit it by hand; change
  `Burble.Groove.@manifest` and rerun this task.
  """

  use Mix.Task

  @shortdoc "Regenerate .well-known/groove/manifest.json from Burble.Groove"

  # Repo-root static manifest, relative to the Mix project root (server/).
  @output_path "../.well-known/groove/manifest.json"

  @impl Mix.Task
  def run(_args) do
    # Compile (and set up load paths) so Burble.Groove and Jason are
    # callable without booting the whole application.
    Mix.Task.run("compile")

    json = Jason.encode!(Burble.Groove.manifest(), pretty: true) <> "\n"

    File.mkdir_p!(Path.dirname(@output_path))
    File.write!(@output_path, json)

    Mix.shell().info("Wrote #{Path.expand(@output_path)} (#{byte_size(json)} bytes)")
  end
end
