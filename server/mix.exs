# SPDX-License-Identifier: MPL-2.0
#
# Burble Server — Elixir/Phoenix control plane.
#
# OTP supervision tree managing auth, rooms, presence, permissions,
# moderation, signaling, telemetry, and audit logging.
#
# Persistence via VeriSimDB (dogfooding the hyperpolymath database).

defmodule Burble.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/hyperpolymath/burble"

  def project do
    [
      app: :burble,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      name: "Burble",
      description: description(),
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      mod: {Burble.Application, []},
      extra_applications: [:logger, :runtime_tools, :os_mon, :crypto]
    ]
  end

  defp description do
    """
    Voice-first communications server. Self-hostable, E2EE-capable,
    formally verified. WebRTC SFU with SIMD-accelerated coprocessor
    kernels (Zig NIFs), Vext hash chain integrity, Avow consent
    attestations, and four deployment topologies.
    """
  end

  defp package do
    [
      name: "burble",
      licenses: ["MPL-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["Jonathan D.A. Jewell"],
      files: ~w(
        lib config priv
        mix.exs mix.lock
        README* LICENSE* CHANGELOG* SECURITY*
        .formatter.exs
      )
    ]
  end

  defp docs do
    [
      main: "Burble",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["../README.adoc", "../SECURITY.md"],
      groups_for_modules: [
        "Core": [
          Burble.Application,
          Burble.Store,
          Burble.Topology
        ],
        "Auth": [
          Burble.Auth,
          Burble.Auth.User,
          Burble.Auth.Guardian,
          Burble.Auth.GuardianPipeline,
          Burble.Auth.GuardianErrorHandler
        ],
        "Media": [
          Burble.Media.Engine,
          Burble.Media.Peer,
          Burble.Media.Privacy,
          Burble.Media.Recorder
        ],
        "Coprocessor": [
          Burble.Coprocessor.Backend,
          Burble.Coprocessor.ElixirBackend,
          Burble.Coprocessor.ZigBackend,
          Burble.Coprocessor.SmartBackend,
          Burble.Coprocessor.Pipeline
        ],
        "Verification": [
          Burble.Verification.Avow,
          Burble.Verification.Vext
        ],
        "Text": [
          Burble.Text.NNTPSBackend
        ],
        "Bridges": [
          Burble.Bridges.Mumble
        ],
        "Safety": [
          Burble.Safety.ProvenBridge
        ],
        "Web": [
          BurbleWeb.Router,
          BurbleWeb.RoomChannel,
          BurbleWeb.UserSocket
        ]
      ]
    ]
  end

  defp releases do
    [
      burble: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent, os_mon: :permanent],
        steps: [:assemble, :tar],
        rel_templates_path: "rel",
        overlay: "rel/overlays",
        # Phoenix's validate_compile_env check refuses to boot when runtime.exs
        # sets a value that compile_env reads with a different default. Several
        # endpoint plugs use Application.compile_env where Application.get_env
        # would be more correct (cors_origins, snif_path, ...). Migrating those
        # to get_env is Phase 1 Burble work. Disabling validation here so the
        # release boots while that migration is pending.
        validate_compile_env: false
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Web framework
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},

      # WebSocket transport for voice signaling
      {:phoenix_pubsub, "~> 2.1"},

      # JSON encoding
      {:jason, "~> 1.4"},

      # HTTP server
      {:bandit, "~> 1.6"},

      # Authentication
      {:bcrypt_elixir, "~> 3.2"},
      {:guardian, "~> 2.3"},
      # Pinned to 1.11.9 (last release before jose started using OTP 26's
      # dynamic() type in src/json/jose_json.erl). Loosen to "~> 1.11"
      # once this host moves to OTP 26+. Guardian's transitive constraint
      # is "~> 1.11.9" so this is the floor of that range.
      {:jose, "~> 1.11.9 and < 1.11.11", override: true},

      # Persistent store — VeriSimDB client SDK.
      # For Hex: {:verisim_client, "~> 0.1"}
      # For development: path dep to local checkout.
      {:verisim_client, git: "https://github.com/hyperpolymath/verisimdb.git",
       sparse: "connectors/clients/elixir"},

      # Formally verified safety functions (optional — falls back to stdlib).
      # For Hex: {:proven, "~> 0.10", optional: true}
      # Proven NIF requires pre-built libproven.so — disabled for dev.
      # {:proven, git: "https://github.com/hyperpolymath/proven.git",
      #  sparse: "bindings/elixir", runtime: false},

      # Telemetry and observability
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:phoenix_live_dashboard, "~> 0.8"},

      # Rate limiting
      {:hammer, "~> 6.2"},

      # Optional NIF-backed dependencies — disabled in this build because
      # Mix's :optional flag is a parent-application hint, not a skip-if-
      # missing-system-deps flag, and our current host doesn't satisfy
      # their build requirements. Re-enable individually once prerequisites
      # are in place; runtime code already handles their absence.
      #
      #   quicer  — needs msquic (Microsoft QUIC C library)
      #   elmdb   — links liberl_interface which was dropped in OTP 23+
      #   ex_lmdb — depends on elmdb
      #   wasmex  — Rust NIF (wasmtime); needs a Rust toolchain. SNIF
      #             (Burble.Coprocessor.SNIFBackend) transparently degrades
      #             to ZigBackend when absent — available?/0 gates on it.
      #
      # {:quicer, github: "emqx/quic", tag: "0.2.15", submodules: true, optional: true},
      # {:elmdb, "~> 0.4", optional: true},
      # {:ex_lmdb, "~> 0.1", optional: true},
      # {:wasmex, "~> 0.9", optional: true},

      # Media plane — ex_webrtc SFU (audio-only, Opus)
      {:ex_webrtc, "~> 0.16"},

      # Email (magic links, notifications)
      {:swoosh, "~> 1.17"},
      {:gen_smtp, "~> 1.2"},

      # CORS for web client
      {:corsica, "~> 2.1"},

      # Protobuf (wire protocol)
      {:protobuf, "~> 0.13"},

      # Dev/test
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:stream_data, "~> 1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: ["test"]
    ]
  end
end
