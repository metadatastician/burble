#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Distinguish untracked implementation debt from prose, templates, generated
# metadata, and issue-linked work. Proof circumventions remain a separate,
# stricter check over proof languages only.
set -uo pipefail
fail=0

readonly allow_file='.cicd-hygiene-allow'
allow_args=()
if [[ -f "$allow_file" ]]; then
  echo "Using allowlist $allow_file:"
  while IFS= read -r pat || [[ -n "$pat" ]]; do
    case "$pat" in
      ''|'#'*) continue ;;
      *)
        echo "  exclude: $pat"
        allow_args+=(":(exclude)$pat")
        ;;
    esac
  done < "$allow_file"
fi

# The horizon is deliberately explicit. These are implementation-language
# files, wherever they occur in the tree. Documentation, workflows,
# machine-readable templates, packaging recipes, and container templates are
# not silently relabelled as application source.
exclude_paths=(
  ':(exclude).github/**' ':(exclude).githooks/**'
  ':(exclude).machine_readable/**' ':(exclude)docs/**'
  ':(exclude)packaging/**' ':(exclude)container/**'
  ":(exclude)$allow_file"
)

source_paths=(
  '*.adb' '*.ads' '*.affine' '*.agda' '*.bash' '*.c' '*.cc' '*.clj' '*.cljs'
  '*.cjs' '*.cpp' '*.cr' '*.cts' '*.cxx' '*.eph' '*.erl' '*.ex' '*.exs'
  '*.fish' '*.fs'
  '*.fsx' '*.gleam' '*.go' '*.h' '*.hh' '*.hpp' '*.hs' '*.idr' '*.java'
  '*.js' '*.jsx' '*.kt' '*.kts' '*.lean' '*.lhs' '*.lua' '*.m' '*.mjs'
  '*.ml' '*.mli' '*.mm' '*.mts' '*.nu'
  '*.php' '*.pl' '*.pm' '*.py' '*.r' '*.rb' '*.res' '*.resi' '*.roc' '*.rs'
  '*.scala' '*.sh' '*.sol' '*.sql' '*.swift' '*.thy' '*.ts' '*.tsx' '*.v'
  '*.vala' '*.vapi' '*.zig'
  "${exclude_paths[@]}"
)

echo 'Scanning implementation source for untracked debt markers...'
debt="$({ git grep --untracked -n -E -w 'TODO|FIXME|XXX|HACK|STUB' -- \
  "${source_paths[@]}" "${allow_args[@]+"${allow_args[@]}"}" || true; } \
  | perl -ne 'print if /:[0-9]+:.*\b(?:TODO|FIXME|XXX|HACK|STUB)\b(?!\(#[0-9]+\))/')"
if [[ -n "$debt" ]]; then
  echo '::error::Untracked debt markers found in implementation source:' >&2
  printf '%s\n' "$debt"
  echo '::error::Resolve the debt or link it as MARKER(#issue).' >&2
  fail=1
else
  echo '  none.'
fi

echo 'Scanning proof code for undeclared circumventions...'
circ="$({ git grep --untracked -n -E -w 'sorry|believe_me|admit|postulate|assert_total' -- \
  '*.idr' '*.lean' '*.v' '*.agda' '*.thy' \
  "${exclude_paths[@]}" \
  "${allow_args[@]+"${allow_args[@]}"}" || true; } \
  | grep -vE ':[0-9]+:[[:space:]]*(\|\|\||--|//|\(\*)' || true)"
if [[ -n "$circ" ]]; then
  echo '::error::Undeclared proof circumventions found:' >&2
  printf '%s\n' "$circ"
  echo "::error::If sanctioned, isolate the axioms, list the module in $allow_file," >&2
  echo '::error::and enforce the exact count with a trusted-base check.' >&2
  fail=1
else
  echo '  none.'
fi

if [[ "$fail" -eq 1 ]]; then
  echo '::error::Code hygiene gate failed.' >&2
  exit 1
fi
echo 'Hygiene check passed.'
