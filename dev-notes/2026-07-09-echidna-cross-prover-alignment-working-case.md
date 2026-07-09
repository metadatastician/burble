<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Working case: echidna cross-prover alignment for the frame-router proofs (Lean ↔ Idris2)

**Follow-up to** `docs/decisions/0014-connection-transport-and-frame-router-link.adoc`
(open question: *do marches' Lean proofs help finish the frame-router's Idris2
proofs, and how far does echidna's corpus/synonym machinery get us?*).

**Date:** 2026-07-09. **Status:** live probe, real output. **Scope note:** the
echidna-side fixes/artifacts below belong in `echidna` (a separate session —
this worktree is Burble-scoped; I ran echidna read-only and worked around its
data in scratch, editing nothing outside `burble/`).

## Question

marches (Lean 4, *proven*) and the typed-frame-router (Idris2, `not-proven/`)
are the same typed-routing lineage. Can echidna's **corpus + synonym** tooling
reduce the "proofs don't port between provers" barrier — concretely, for the
concepts marches' proofs depend on?

## What echidna actually is (verified)

Neurosymbolic multi-prover platform. Relevant surface, from `target/debug/echidna`:

* `corpus crossquery <CLASS>` — cross-prover lookup by **`semantic_class`** over
  the hand-curated `data/synonyms/*.toml` tables. **This is the alignment probe.**
* `corpus near <QUERY>` — cosine similarity over "octad" embeddings (semantic
  neighbours beyond the hand-seeded map).
* `corpus ingest --root R --adapter A` — project-level indexer, **but adapter is
  `currently only agda`** → cannot auto-ingest marches (Lean) / frame-router
  (Idris2) at the project level yet.
* Synonym tables exist for 18 systems incl. `lean4.toml`, `idris2.toml`,
  `coq.toml`, `agda.toml`; each entry carries `canonical`, `aliases`,
  `tactic_class`, `semantic_class`.

## Run (reproducible)

```
BIN=<echidna>/target/debug/echidna
# NB: crossquery loads ALL tables and hard-fails if ANY is malformed (see bugs).
# Workaround used: sanitized copies in scratch, dropped 3 unparseable files.
$BIN corpus crossquery well-foundedness --synonyms-dir <clean-synonyms>
$BIN corpus crossquery wf-induction     --synonyms-dir <clean-synonyms>
$BIN corpus crossquery accessibility    --synonyms-dir <clean-synonyms>
```

## Result — the concordance (real output)

| semantic_class | Lean 4 | Idris 2 | note |
|---|---|---|---|
| `well-foundedness` | `WellFounded` (aliases `WellFounded R`, `Wf`) | `WellFounded` (same aliases) | **identical** — direct port |
| `accessibility` | `Acc` (aliases `Acc r x`, `Accessible`) | `Accessible` (aliases `Acc`, `Acc R x`) | **renamed** — Lean `Acc` = Idris2 `Accessible`; bridged only via aliases |
| `wf-induction` | `WellFounded.induction` (aliases `WellFoundedRecursion`, `termination_by`) | `wfRec` (aliases `WellFounded.induction`, `well-founded-induction`) | **renamed** — Lean `termination_by` / `WellFounded.induction` = Idris2 `wfRec` |

(`induction` alone: no entry — not seeded under that class.)

## Findings — "how far does it get us?"

**It genuinely solves the alignment/concordance layer**, and — the valuable part —
**it catches the non-obvious renames** that cause "synonym blindness" when porting:
a human/AI translating marches' termination machinery would likely miss that
Lean's `termination_by` / `WellFounded.induction` is Idris2's **`wfRec`**, and that
Lean's `Acc` is Idris2's **`Accessible`**. echidna states these directly. Since
marches' loop-freedom / valley-freedom proofs *are* built on well-foundedness +
accessibility + well-founded recursion, this concordance covers the **core proof
vocabulary** of the port.

**It does not** (honest limits, unchanged from ADR-0014):
* translate proof terms / tactic scripts (`trace_worsens`'s Lean proof → a
  type-checking Idris2 term);
* reconcile foundations (Lean quotients / classical / proof-irrelevance vs
  Idris2 QTT);
* do project-level auto-alignment yet (ingest = agda-only).

**Best realistic use (neurosymbolic, not translation):** align the *goal* via
`semantic_class`, then use echidna's proof **search** to *re-derive* it natively
in Idris2 — guided by the concordance + `corpus near` embeddings. Port the
statement, re-prove in the target; don't port the tactic script.

## Bugs found in echidna (for an echidna session)

1. **3 synonym tables fail TOML parse** — `hol4.toml`, `hol_light.toml`,
   `isabelle.toml` contain invalid `\`` escapes (backslash-backtick inside basic
   strings; e.g. `isabelle.toml:87`, `hol4.toml:111`). Fix: unescape (backticks
   are literal in TOML) or use literal `'''` strings.
2. **Fragile loader** — `crossquery` loads *all* tables and **hard-fails if any
   one is malformed**, so the 3 broken files take down *every* cross-prover query.
   Should skip-with-warning per file, not abort. (High-value, low-effort hardening.)

## Next steps

* (echidna) fix the 3 tables + harden the loader; add Lean + Idris2 `ingest`
  adapters; then re-run at project level over marches + frame-router.
* (frame-router) use this concordance to re-prove the aligned goals natively in
  Idris2 (search-guided), rather than translating Lean tactics — the ADR-0014
  "first shippable form" path, proofs deferred but now with a real head start.
