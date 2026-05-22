# SPDX-License-Identifier: MPL-2.0
# selur-compose — Nix development shell
# Mirrors the verisimdb flake pattern used across hyperpolymath.
#
# Usage:
#   nix develop           # enter dev shell
#   nix develop --command just test   # run tests in dev shell
{
  description = "selur-compose — TOML-native Podman compose CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        # Pin to the exact MSRV used in rust-toolchain.toml.
        rustToolchain = pkgs.rust-bin.stable."1.78.0".default.override {
          extensions = [ "rustfmt" "clippy" "rust-src" ];
          targets = [
            "x86_64-unknown-linux-musl"
            "aarch64-unknown-linux-musl"
          ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # Rust toolchain — pinned to MSRV 1.78.0
            rustToolchain

            # Container runtime (must be rootless-capable on Linux)
            pkgs.podman

            # Test runner (faster than cargo test)
            pkgs.cargo-nextest

            # Release engineering
            pkgs.cargo-dist

            # Task runner
            pkgs.just

            # TOML linter / formatter
            pkgs.taplo

            # C build system (for crates with native deps)
            pkgs.gnumake
            pkgs.pkg-config

            # OpenSSL (for crates that link against it via openssl-sys)
            pkgs.openssl
            pkgs.openssl.dev
          ];

          # Expose OpenSSL headers to the Rust openssl-sys crate.
          PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig";

          shellHook = ''
            echo "selur-compose dev shell"
            echo "  rust: $(rustc --version)"
            echo "  cargo: $(cargo --version)"
            echo "  podman: $(podman --version 2>/dev/null || echo 'not found')"
            echo "  just: $(just --version)"
          '';
        };
      }
    );
}
