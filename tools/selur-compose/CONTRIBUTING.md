<!-- SPDX-License-Identifier: MPL-2.0 -->
# Contributing to selur-compose

Thank you for considering a contribution. selur-compose is a Rust project that
follows the hyperpolymath language policy: **Rust, bash, and YAML only — no
Python, Go, or Node.js** in any form.

## Prerequisites

- **Rust 1.78 or later** (stable channel). Install via https://rustup.rs.
- **cargo-nextest** for running the test suite: `cargo install cargo-nextest`
- **podman 5.4+** on `$PATH` if you want to run the integration or e2e tests.
- **just** for the task runner: https://just.systems

## Building

```bash
git clone https://github.com/hyperpolymath/selur-compose
cd selur-compose
cargo build --workspace
```

A debug binary lands at `target/debug/selur-compose`.

For a release build:

```bash
cargo build --release
```

## Running tests

Unit tests (no podman required — fast, run before every PR):

```bash
just test
# or equivalently
cargo nextest run --workspace
```

Integration tests (require podman 5.4+ on PATH):

```bash
just test-it
# cargo nextest run --workspace --features podman-it
```

End-to-end tests (require sibling repos checked out at `../boj-server`):

```bash
just test-e2e
# cargo nextest run --workspace --features e2e
```

## Code style

Format with `cargo fmt --all`. Lint with `cargo clippy --workspace --all-targets -- -D warnings`.

The CI enforces both as hard failures. Run locally before opening a PR:

```bash
just fmt-check
just lint
```

Key style points:

- Prefer `thiserror` in library crates; use `anyhow` only in the binary crate (`crates/selur-compose/`).
- All new public items require rustdoc (`#![deny(missing_docs)]` is enforced on the schema crate).
- New subcommands go in `crates/selur-compose/src/cmd/`.
- New schema fields must be accompanied by round-trip tests in `crates/selur-compose-schema/tests/`.

## Snapshot tests

selur-compose uses `insta` for snapshot tests. When you change behaviour that
affects a snapshot, run:

```bash
just snapshot-review
# cargo insta review
```

Review and accept each changed snapshot, then commit the updated `.snap` files
alongside your code change. Snapshots that change without an accompanying code
change are a red flag.

## Opening a pull request

1. Fork the repo and create a branch: `git checkout -b feat/my-thing`.
2. Make your changes; include tests.
3. Run `just fmt-check && just lint && just test` — all must be green.
4. Open a PR against `main`. Include a short description of *why* the change is
   needed, not just *what* it does.

## Language policy

Python, Go, and Node.js are banned across all hyperpolymath projects.
Build scripts must be bash or `just` recipes. No `npm`, no `pip`, no `go get`.
