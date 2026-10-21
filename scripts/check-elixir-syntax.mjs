#!/usr/bin/env -S deno run --allow-read --allow-env
// SPDX-License-Identifier: MPL-2.0
//
// check-elixir-syntax.mjs — parse the Elixir tree with a real grammar.
//
// Why this exists: CI compiles and tests the server, but there are situations
// where no Erlang/Elixir toolchain is available (restricted sandboxes, agent
// environments, a laptop mid-upgrade). `grep -c 'def'` and bracket counting do
// not catch a malformed `case`, a stray `end`, or a call to a function that no
// longer exists. This does.
//
//   deno run --allow-read --allow-env scripts/check-elixir-syntax.mjs server/lib server/test
//   deno run --allow-read --allow-env scripts/check-elixir-syntax.mjs --calls server/lib server/test
//   deno run --allow-read --allow-env scripts/check-elixir-syntax.mjs --calls --strict server/lib server/test
//
// Exit codes: 0 clean, 1 parse errors, 2 unresolved calls under --strict.
// The call check is advisory by default because `use`-generated functions are
// invisible to a parser (Phoenix.Endpoint/Presence, Guardian, ...).
//
// Setup (once, using the committed Deno manifest and lockfile):
//   deno install --config scripts/deno.json --frozen
//
// Limits, stated plainly: this is a PARSER, not a compiler. It cannot resolve
// macros, `use`-generated functions, protocols, or behaviour callbacks, and it
// does not type-check. Treat a clean run as "syntactically sound and free of
// obviously-dead cross-module calls", never as "builds".

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

let Parser, Language;
try {
  ({ Parser, Language } = require('web-tree-sitter'));
} catch {
  console.error(
    'web-tree-sitter is not installed. Run:\n' +
      '  deno install --config scripts/deno.json --frozen'
  );
  process.exit(3);
}

const wasm = (() => {
  const candidates = [
    path.join('scripts', 'node_modules', 'tree-sitter-elixir', 'tree-sitter-elixir.wasm'),
    path.join('node_modules', 'tree-sitter-elixir', 'tree-sitter-elixir.wasm')
  ];
  for (const c of candidates) if (fs.existsSync(c)) return c;
  console.error('tree-sitter-elixir.wasm not found. Run the Deno install above.');
  process.exit(3);
})();

await Parser.init();
const lang = await Language.load(wasm);
const parser = new Parser();
parser.setLanguage(lang);

// ── arguments ───────────────────────────────────────────────────────────────

const argv = process.argv.slice(2);
const checkCalls = argv.includes('--calls');
const roots = argv.filter(a => !a.startsWith('--'));
if (!roots.length) roots.push('server/lib', 'server/test');

// ── file discovery ──────────────────────────────────────────────────────────

function collect(p, out = []) {
  const st = fs.statSync(p);
  if (st.isFile()) {
    if (/\.exs?$/.test(p)) out.push(p);
    return out;
  }
  for (const e of fs.readdirSync(p, { withFileTypes: true })) {
    collect(path.join(p, e.name), out);
  }
  return out;
}

const files = [...new Set(roots.flatMap(r => collect(r)))].sort();
if (!files.length) {
  console.error('no .ex/.exs files under: ' + roots.join(' '));
  process.exit(1);
}

const text = (n, src) => (n ? src.slice(n.startIndex, n.endIndex) : null);
const target = n => n.childForFieldName('target');
const argsNode = n => n.children.find(c => c.type === 'arguments');

// ── pass 1: parse ───────────────────────────────────────────────────────────

let parseErrors = 0;

for (const file of files) {
  const src = fs.readFileSync(file, 'utf8');
  const tree = parser.parse(src);
  const bad = [];
  const walk = n => {
    if (n.type === 'ERROR' || n.isMissing) bad.push(n);
    for (const c of n.children) walk(c);
  };
  walk(tree.rootNode);

  if (bad.length) {
    parseErrors++;
    console.error(`\n${file}`);
    for (const e of bad.slice(0, 5)) {
      const row = e.startPosition.row;
      console.error(`  ${e.type}${e.isMissing ? ' (missing)' : ''} at ${row + 1}:${e.startPosition.column + 1}`);
      console.error(`    ${(src.split('\n')[row] ?? '').slice(0, 110)}`);
    }
  }
}

console.log(`parsed ${files.length} file(s), ${parseErrors} with parse errors`);
if (parseErrors) process.exit(1);
if (!checkCalls) process.exit(0);

// ── pass 2 (opt-in): cross-module arity check ───────────────────────────────
//
// Catches `Mod.fun(args)` where fun/arity is not defined in the project module
// Mod — the class of bug that appears when a function is renamed or removed.
// Only fully-qualified calls and calls whose short name is aliased in the same
// file are checked, so there are no guesses.

const modules = new Map(); // "Full.Name" -> Set("fun/arity")

for (const file of files) {
  const src = fs.readFileSync(file, 'utf8');
  const tree = parser.parse(src);
  const stack = [];

  const walk = n => {
    if (n.type === 'call') {
      const t = target(n);
      const tname = t && t.type === 'identifier' ? text(t, src) : null;

      if (tname === 'defmodule') {
        const name = text(argsNode(n)?.namedChildren[0], src);
        if (name) {
          if (!modules.has(name)) modules.set(name, new Set());
          stack.push(name);
        }
      } else if (['def', 'defp', 'defmacro', 'defguard'].includes(tname)) {
        const cur = stack[stack.length - 1];
        let head = argsNode(n)?.namedChildren[0];
        if (head && head.type === 'binary_operator') {
          const op = head.childForFieldName('operator');
          if (op && text(op, src) === 'when') head = head.childForFieldName('left');
        }
        if (cur && head) {
          let fname = null;
          let fnCall = null;
          if (head.type === 'call') {
            fnCall = head;
            fname = text(target(head), src);
          } else if (head.type === 'identifier') {
            fname = text(head, src);
          }
          if (fname && fname !== 'unquote') {
            const params = fnCall
              ? fnCall.children.find(c => c.type === 'arguments')?.namedChildren ?? []
              : [];
            const defaults = params.filter(
              p =>
                p.type === 'binary_operator' &&
                text(p.childForFieldName('operator'), src) === '\\\\'
            ).length;
            for (let i = params.length - defaults; i <= params.length; i++) {
              modules.get(cur).add(`${fname}/${i}`);
            }
          }
        }
      }
    }
    for (const c of n.children) walk(c);
    if (n.type === 'call' && target(n) && text(target(n), src) === 'defmodule') stack.pop();
  };
  walk(tree.rootNode);
}

const REFLECTIVE = new Set(['__info__', '__struct__', 'behaviour_info', 'module_info']);

let unresolved = 0;

for (const file of files) {
  const src = fs.readFileSync(file, 'utf8');
  const tree = parser.parse(src);
  const stack = [];

  const aliasMap = node => {
    const map = new Map();
    const walk = n => {
      if (n.type === 'call' && target(n) && text(target(n), src) === 'alias') {
        const a = argsNode(n);
        const first = a?.namedChildren[0];
        if (first && first.type === 'alias') {
          const full = text(first, src);
          let as = full.split('.').pop();
          for (const kid of a.namedChildren.slice(1)) {
            if (kid.type === 'keywords') {
              const pair = kid.namedChildren.find(
                x => x.type === 'pair' && text(x.namedChildren[0], src).replace(':', '') === 'as'
              );
              if (pair) as = text(pair.namedChildren[1], src);
            }
          }
          map.set(as, full);
        }
      }
      for (const c of n.children) walk(c);
    };
    walk(node);
    return map;
  };

  const walk = n => {
    const t = n.type === 'call' ? target(n) : null;
    const entering = t && t.type === 'identifier' && text(t, src) === 'defmodule';
    if (entering) {
      stack.push({ aliases: aliasMap(n) });
    }

    // Skip @spec/@type attributes (type references) and captures.
    let skipped = false;
    for (let p = n.parent; p && !skipped; p = p.parent) {
      if (p.type === 'capture_expression') skipped = true;
      if (p.type === 'unary_operator' && p.children[0] && text(p.children[0], src) === '@') {
        const attr = text(p.children[1], src);
        if (['spec', 'type', 'typep', 'opaque', 'callback', 'macrocallback'].includes(attr)) {
          skipped = true;
        }
      }
    }

    if (!skipped && n.type === 'call' && t && t.type === 'dot') {
      const left = t.childForFieldName('left');
      const right = t.childForFieldName('right');
      if (left && left.type === 'alias' && right && right.type === 'identifier') {
        const raw = text(left, src);
        const fn = text(right, src);
        let mod = null;
        if (raw.includes('.')) mod = raw;
        else if (stack.length) mod = stack[stack.length - 1].aliases.get(raw) ?? null;

        if (mod && modules.has(mod) && !REFLECTIVE.has(fn)) {
          let arity = argsNode(n)?.namedChildren.length ?? 0;
          const parent = n.parent;
          if (parent && parent.type === 'binary_operator') {
            const op = parent.childForFieldName('operator');
            const rhs = parent.childForFieldName('right');
            const isRight = rhs && rhs.startIndex === n.startIndex && rhs.endIndex === n.endIndex;
            if (op && text(op, src) === '|>' && isRight) arity += 1;
          }
          if (!modules.get(mod).has(`${fn}/${arity}`)) {
            unresolved++;
            const row = n.startPosition.row;
            console.log(
              `${file}:${row + 1}  ${mod}.${fn}/${arity}\n` +
                `    ${(src.split('\n')[row] ?? '').trim().slice(0, 110)}`
            );
          }
        }
      }
    }

    for (const c of n.children) walk(c);
    if (entering) stack.pop();
  };
  walk(tree.rootNode);
}

console.log(
  `\n${modules.size} project module(s); ` +
    `${unresolved} unresolved cross-module call(s) ` +
    `(macro-generated functions appear here as false positives)`
);

const strict = argv.includes('--strict');
process.exit(unresolved && strict ? 2 : 0);
