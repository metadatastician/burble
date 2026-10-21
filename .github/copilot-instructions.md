<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) {{CURRENT_YEAR}} {{AUTHOR}} (hyperpolymath) <{{AUTHOR_EMAIL}}> -->
<!-- Authoritative source: docs/practice/AI-CONVENTIONS.adoc -->

# Copilot Instructions

## Before Writing Code

- Read `0-AI-MANIFEST.a2ml` in the repo root for canonical file locations.
- State files (.a2ml) live in `.machine_readable/` ONLY, never the root.

## License

- SPDX: `MPL-2.0` on all new files.
- Never use AGPL-3.0.
- Copyright: `{{AUTHOR}} (hyperpolymath) <{{AUTHOR_EMAIL}}>`

## Code Style

- Use descriptive variable names.
- Annotate and document all files.
- Add SPDX header to every source file.
- Use `just` for build/test/lint commands.

## Banned Patterns

- Idris2: no `believe_me`, no `assert_total`
- Haskell: no `unsafeCoerce`, no `unsafePerformIO`
- OCaml: no `Obj.magic`
- Coq: no `Admitted`
- Lean: no `sorry`
- Rust: no `transmute` unless FFI with `// SAFETY:` comment

## Banned Languages

- No TypeScript (use ReScript; AffineScript where a `.affine` file exists)
- No npm / yarn / pnpm as package managers, and no Node.js as a runtime — use
  **Bun** (`bun install`, `bun run`, `bun test`). A `package.json` is not banned:
  it is Bun's manifest format, and ReScript needs one to resolve
  `@rescript/core` under Bun.
- **Bun is the default estate-wide. Do not open a PR that moves a script, test,
  manifest or CI lane from Bun to Deno** — that direction was tried (see the
  closed #248) and reverted. `deno.json` files stay because the template
  expects the manifest; their tasks delegate to Bun.
- No Go (use Rust)
- No Python (use Julia or Rust)

## Containers

- Use Podman, never Docker.
- Name the file `Containerfile`, never `Dockerfile`.
- Base image: `cgr.dev/chainguard/wolfi-base:latest`.

## ABI/FFI

- ABI definitions in Idris2 (`src/interface/abi/`).
- FFI implementations in Zig (`src/interface/ffi/`).
- Generated C headers in `src/interface/generated/`.

## State Files

Never create these in the repo root:
STATE.a2ml, META.a2ml, ECOSYSTEM.a2ml, AGENTIC.a2ml, NEUROSYM.a2ml, PLAYBOOK.a2ml.
They belong in `.machine_readable/` only.
