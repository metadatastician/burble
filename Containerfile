# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Containerfile for Burble — P2P voice chat + AI data channel
#
# Build: podman build -t burble:latest -f Containerfile .
# Run:   podman run --rm -it -p 4020:4020 burble:latest
#
# Multi-stage build:
#   1. Elixir build stage — compile OTP release
#   2. Runtime stage — minimal Chainguard image

# --- Build stage ---
FROM cgr.dev/chainguard/wolfi-base:latest AS build

# Install Elixir, Erlang, and build dependencies.
# Uses glibc (not musl) — Chainguard wolfi uses glibc by default.
RUN apk add --no-cache \
    elixir \
    erlang \
    erlang-dev \
    git \
    glibc-dev \
    gcc \
    make \
    pkgconf \
    openssl-dev \
    cmake

# Install Rust toolchain for proven NIF dependency.
RUN apk add --no-cache rust cargo

# Install OCaml toolchain for AffineScript compiler.
RUN apk add --no-cache \
    ocaml \
    ocaml-compiler-libs \
    opam \
    m4

WORKDIR /build

# Copy mix config first for dependency caching.
# Build context is the repo root; server code lives in server/.
COPY server/mix.exs server/mix.lock ./
COPY server/config config

# Fetch and compile dependencies.
ENV MIX_ENV=prod
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod && \
    mix deps.compile

# Copy application source.
COPY server/lib lib
COPY server/priv priv
COPY server/rel rel

# Build the OTP release.
RUN mix compile && \
    mix release burble

# ── AffineScript compiler ──
COPY tools/affinescript /build/tools/affinescript
WORKDIR /build/tools/affinescript
RUN opam init --disable-sandboxing --bare --yes && \
    opam switch create . --packages "ocaml-base-compiler.5.1.1" --yes || true && \
    eval $(opam env) && \
    opam install . --deps-only --yes && \
    dune build

# --- Runtime stage ---
FROM cgr.dev/chainguard/wolfi-base:latest

# Install minimal runtime dependencies.
RUN apk add --no-cache \
    libstdc++ \
    openssl \
    ncurses-libs \
    libgcc

WORKDIR /app

# Copy the OTP release from the build stage.
COPY --from=build /build/_build/prod/rel/burble ./

# Copy the AffineScript compiler binary.
COPY --from=build /build/tools/affinescript/_build/default/bin/main.exe /usr/local/bin/affinec

# Copy the AffineScript stdlib so the compiler can find it.
COPY --from=build /build/tools/affinescript/stdlib /usr/local/lib/affinescript/stdlib

# Copy static web client files.
COPY client/web /app/client/web

ENV AFFINESCRIPT_STDLIB=/usr/local/lib/affinescript/stdlib

# Non-root user (Chainguard default).
USER nonroot

# Expose the Phoenix server port (matches PORT env in runtime.exs, default 4020).
EXPOSE 4020

# Health check.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD /app/bin/burble rpc "Burble.Application.health_check()" || exit 1

ENTRYPOINT ["/app/bin/burble"]
CMD ["start"]
