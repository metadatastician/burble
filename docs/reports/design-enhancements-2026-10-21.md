# Design enhancements for Burble, drawn from the hyperpolymath type-theory and reversibility repos

**Date:** 2026-10-21
**Commit surveyed:** `24ec8bc` (Burble), plus uncommitted E2EE work described in ADR-0016
**Method:** read the README of each named repository via the GitHub API, then
checked every proposal against Burble's actual source before writing it down.
No proposal here is based on a repository's name, description, or ambition —
each cites what that README claims about its own status, *including its
retractions*, because several of these repos are unusually careful about not
over-claiming and that care is itself the most transferable thing in them.

**What this is not.** This is not an integration plan, not an endorsement, and
not an evaluation of whether the research in those repos is correct. It is a
list of ideas Burble could borrow, with the cost and the first step for each.
Effort estimates assume one person who knows Burble.

---

## 1. What was surveyed

| Repo | Language | What its own README says it is | Status it claims |
|---|---|---|---|
| `choreographic-types` | Agda | Graded multiparty session / choreographic type theory; global type as partial causal order, projected to local types, each edge graded by an echo loss-grade and an epistemic warrant | Keystone **K-CUT** proven for a finite binary-choice fragment; recursion and full merge open |
| `secret-types` | Agda | Confidentiality labels constraining value flow, declassification only at explicit audited points; target property termination-insensitive noninterference | Core theorem **proven** for a two-point lattice; "a label is not cryptography" |
| `epistemic-types` | Agda | Standpoint-indexed modalities separating knowledge (factive), belief (non-factive) and warrant; proof transport gives a receipt | Structural laws proven generically; incomplete as a logic by design |
| `echo-types` | Agda | Proof-relevant fibers as witnesses for *structured* loss — irreversible maps whose fiber retains what was lost | Taxonomy + separation proofs; has a retraction ledger |
| `occupancy-types` | Idris + IR calculus | Stepwise resource-bounding types (deterministic memory first, network second) plus a `stackcert` certificate checker | ULTRAPLAN rungs; claims-to-files map with verification status |
| `tropical-types` | Lean 4 | Max-plus algebra for compositional *worst-case* bounds (latency, stack, adversarial rounds); includes a no-go theorem | Dependency-free, no `sorry` |
| `typell` | Rust (planned) | Verification kernel for typed queries: dependent, linear, session, QTT, effect, modal types + proof-carrying code | Early; it is infrastructure for PanLL |
| `typed-wasm` | Idris 2 | Progressive type-safety *levels* L1–L10 for WASM linear memory, `believe_me: 0` in the checked package | Levels L11–L12 draft |
| `anytype` | Idris 2 | Reference kernel: "pick the resource algebra, get the discipline" | Early scaffolding; deliberately renamed away from *EveryType* to avoid over-claiming |
| `typedqliser` | Rust | Type checker in front of any query language; proves properties, passes the query through unchanged | Highest priority in the `-iser` family; early |
| `residual-evidence-types` | Agda | Evidence-indexed residual types: the alternative explanations compatible with an observation | Explicit work-in-progress, no stable API |
| `absolute-zero` | Idris 2 / Agda / Z3 | Certified Null Operations (state-preserving) and Observational Null Disclosure (trace constant over the secret, relative to an observation model `O`) | OND-1..5 proved; every OND claim ships a **residue list of out-of-scope observables** |
| `januskey` | Rust | File operations carrying their own inversion metadata in an append-only, content-addressed log | Mechanism implemented; **formal reversibility proofs explicitly pending** |
| `hpm-crypto-rsr` | Idris 2 ABI + Zig FFI | HMAC-SHA256, RS256, base64url with KATs against OpenSSL | 23/23 Zig tests passing |
| `http-capability-gateway` | Elixir | Declarative spec governing which HTTP verbs are exposed; loader → validator → compiler → enforcement → structured audit log | "real implementation … narrow, in-progress"; gaps named |
| `presswerk` | Rust + Idris 2 | Print app using `age` (X25519) for storage at rest, append-only encrypted audit log, protocol downgrade ladder starting from the most secure | Feature-complete claims with an audit trail |
| `checky-monkey` | Haskell | Registry/validator for userscripts across managers | Not relevant to Burble's core; see §4 |

---

## 2. The proposals

Ordered by (value to Burble now) ÷ (cost). Each carries a **first step** small
enough to do in an afternoon, so none of these is a leap of faith.

### D-1. Ship a residue list with every privacy claim (from `absolute-zero`)

`absolute-zero` makes its honesty structural: an OND claim is "the observable
trace is constant over the secret **relative to a declared observation model
`O`**", and *"every OND claim ships a residue list of out-of-scope observables:
the honest boundary between the proof and the physical metal."*

Burble now makes a comparable claim — ADR-0016, "the server has no capability
to see content" — and states its gaps in prose. Prose drifts; a residue list
doesn't, because it is a field.

**Proposal.** Give `Burble.Media.E2EE.room_status/1` (already returns
`key_custody: :peers`) two more keys, populated from module attributes:

* `guarantees:` — what holds *by construction* (e.g. "the server holds no
  private key", "a departing peer cannot derive the next epoch's key").
* `residues:` — what is explicitly **not** covered. For Burble today this must
  include at least: room membership and timing metadata; packet sizes; that
  DTLS-SRTP terminates at the SFU; that the browser frame layer does not exist;
  that the server still runs a content pipeline in `:e2ee` rooms.

Then make ADR-0016's §Gaps and the README's scoreboard *generated from or
checked against* that list, so the code cannot claim more than the document.

**Why it matters here specifically.** Burble's failure mode so far has not been
bad crypto, it has been claims outrunning code (`enabled: true`,
`e2ee_keys_generated: true`). A residue list is the mechanical fix for that
class of bug.

**Cost:** S (a module attribute + a test that asserts the list is non-empty and
mentions the four known gaps). **First step:** add the attribute and assert it
in a test.

---

### D-2. Audited declassification points for anything the server sees in clear (from `secret-types`)

`secret-types` is precise about its own boundary: *"A label is not
cryptography… The baseline declassifies nothing… any release requires a
separate policy and theorem."* Declassification is not banned — it is
**enumerated and audited**.

Burble has one such point and it is currently implicit:
`Burble.Media.Engine.add_peer/4` builds a `Burble.Coprocessor.Pipeline` for
every participant, and that pipeline runs echo-cancel, denoise and Opus encode
over PCM — that is, the server sees content. ADR-0011 §3 says all of that
belongs at the edge. After this round the engine refuses a *key* in `:e2ee`
rooms (`pipeline_key` is forced to `nil` and logged), but the pipeline still
runs, and nothing records that it did.

**Proposal.** One module, `Burble.Security.Declassify`, with a single entry
point taking `{site, room_id, reason, actor}`. Every place that hands content
to a server-side component calls it; it appends a structured record (reusing
`Burble.Audit` — see D-4) and returns `:ok`. A compile-time list of allowed
`site` atoms means a new declassification point cannot be added without editing
the list — the same "loader → validator" shape as
`http-capability-gateway`.

**Cost:** S–M. **First step:** enumerate the sites (there appear to be two:
the coprocessor pipeline and RTSP egress) and add the module with the two
call sites; gate the pipeline on it.

---

### D-3. An HTTP exposure matrix that fails the build (from `http-capability-gateway`)

The gateway is an Elixir service that *"loads a Verb Governance Spec (DSL v1),
validates it, compiles it into fast enforcement rules"* and logs every decision
structurally. Its honesty about status ("narrow, in-progress") is the point:
the mechanism is small and the value is in the spec being reviewable.

Burble's `server/lib/burble_web/router.ex` exposes **42 routes** with verb
choices made ad hoc — `delete "/auth/logout"`, `put "/rooms/:id/routing/mode"`,
`post "/rooms/:id/kick"`. Burble already carries `.machine_readable/policies/`
(`MAINTENANCE-AXES.a2ml`), so the idiom exists in-repo.

**Proposal.** A small data file — `server/priv/policies/http-exposure.a2ml` (or
JSON) — listing every route as `{verb, path, auth_class, idempotent?, audit?}`,
plus an ExUnit test that walks `BurbleWeb.Router.__routes__/0` and fails when a
route is missing from the matrix or when a non-idempotent verb is used where
`idempotent?` is claimed. This turns "we reviewed the API surface" into a build
gate, and the matrix is exactly the artefact a security review asks for.

**Cost:** S. **First step:** generate the matrix from `__routes__/0` (42 rows,
one command) and commit it unchanged; the gate then only prevents drift.

---

### D-4. Give moderation an inverse, not just a log (from `januskey`)

JanusKey's thesis is that *"operations carry their own inversion metadata"* in
an append-only, content-addressed log, so *"rolling back is a metadata lookup,
not a filesystem search"*. Its README is careful that the proofs are pending —
what is implemented is the mechanism.

Burble's `Burble.Audit.log/3` (`server/lib/burble/audit/audit.ex:9`) builds a
map, calls `Logger.info/1`, and returns `{:ok, entry}`. **It persists nothing.**
`Burble.Moderation` performs kick, ban, mute, move and timeout, and describes
itself as maintaining "an audit trail (every action is logged via
`Burble.Audit`)" — which today means a log line that rotates away.

**Proposal.** Two separable steps, either of which is worth doing alone:

1. *Persistence.* Make `Audit.log/3` write to a store and keep the `Logger`
   call as secondary output. Without this, every "audited" claim in the codebase
   is unbacked.
2. *Inversion.* For each reversible moderation action, store
   `inverse: {action, params}` — mute → unmute, kick → invite, move → previous
   room, ban → unban — and expose `Burble.Moderation.undo(entry_id, actor)`.
   Irreversible actions (nothing in moderation is truly irreversible) must
   declare `inverse: :none` explicitly rather than by omission.

The design rule worth stealing verbatim: **an operation that cannot describe
its own inverse has to say so.**

**Cost:** M. **First step:** persistence (the smaller, more urgent half), with
the inverse field reserved in the record shape.

---

### D-5. Type the degradation ladder by what each rung loses (from `echo-types` + `choreographic-types`)

`echo-types` targets "a third case: **irreversible maps where the fiber over
each output retains a proof-relevant constraint on what was lost**" — loss that
is structured, not total. `choreographic-types` composes this into grades on
session edges, with a proven statement (K-CUT-LOSS) that *"loss is
type-determined"* for its finite fragment.

ADR-0011 §5 defines Burble's ladder — full Opus → adaptive low bitrate →
text-as-speech → text-only — as a resilience promise ("never drop the call"),
and the ladder exists in no code today (`Burble.Network.AWOL` mentions
"degradation" only as the thing it routes around).

**Proposal.** When the ladder is implemented, define it as data:

```
%{rung: :text_speech, grade: 2, preserves: [:words, :speaker, :timing],
  loses: [:prosody, :emotion, :overlap], recoverable?: false}
```

and surface the current rung, with what it has lost, in the room UI and in
telemetry. The point is the honest inverse of "never drop the call": a call that
has degraded has *lost something*, and the user should be told what rather than
experiencing unexplained degradation. This is cheap and can be specified now,
before the implementation exists, which is the right order.

**Cost:** S to specify, M to implement. **First step:** write the rung table in
ADR-0011 or a new ADR, with `preserves`/`loses` per rung.

---

### D-6. Presence should distinguish knowledge from belief (from `epistemic-types`)

`epistemic-types` gives Burble's hardest design question a vocabulary. It
separates a **factive** modality (`reflect : E κ A → A` — what is available is
true, i.e. knowledge) from a **belief** modality (*"Intentionally no `reflect`"*),
and it adds warrants: *"a warrant records evidence without assuming soundness.
Proof transported across a boundary becomes a receipt."*

Burble's presence layer reports "who is in the room". Some of those facts are
cryptographically established (a PAKE/SAS-verified identity, ADR-0003); most are
merely asserted by a peer or the server. They are currently the same kind of
value.

**Proposal.** In `Burble.Presence` and ADR-0010's trust zones, replace bare
booleans with a small tagged value: `{:verified, receipt}` (factive — carries
what was checked and by whom) versus `{:claimed, warrant}` (non-factive — carries
who asserted it). The UI can then say "verified" only where a receipt exists,
which is the same discipline as D-1 but for identity instead of confidentiality.
The "receipt must be sound-checked by the receiver" rule maps directly onto
Burble's bridge/extension attestation: a signed claim from another server should
be a receipt the local server verifies, not a fact it adopts.

**Cost:** M. **First step:** add the two-variant type and use it for the
`verified` flag(s) in presence first, leaving the wire format alone.

---

### D-7. Publish E2EE as a *level*, with the level stated (from `typed-wasm`)

`typed-wasm` advertises progressive type safety as numbered levels (L1–L10
checked, L11–L12 draft) and a `believe_me: 0` badge — the badge is the claim
that no proof obligation was skipped.

Burble's E2EE status is a paragraph. A paragraph invites reading past it.

**Proposal.** Define and publish levels, e.g.:

| Level | Meaning | Burble today |
|---|---|---|
| E0 | DTLS-SRTP only (hop-by-hop, terminated at the SFU) | **← this is where every room is** |
| E1 | Peers generate keypairs; server coordinates public keys and epochs | server side done |
| E2 | Room key sealed peer-to-peer; server relays opaque blobs | server side done |
| E3 | Frames encrypted at the sender, decrypted at the receiver | not started |
| E4 | Level claims carry a residue list (D-1) and are tested | not started |

Then `room_status/1` and the README both report `level: :e0` today. This is one
afternoon of writing and it permanently ends the ambiguity of the word "E2EE"
in Burble's own materials — a reader who wants the short version reads one
letter.

**Cost:** S. **First step:** put the table in ADR-0016 and have the README link
to it instead of re-describing.

---

### D-8. Model per-room resource caps as a certificate (from `occupancy-types`)

`occupancy-types` bounds resources stepwise and ships a `stackcert` certificate
checker: the claim "this fits" is a small artefact that can be re-checked by
someone who does not trust the producer.

ADR-0016 introduced hard caps — `@max_peers 512`, `@max_sealed_bytes 512`,
one blob per peer per epoch — and today they are `if` statements inside a
GenServer.

**Proposal.** A pure `Burble.Media.E2EE.capacity_certificate/1` returning
`%{peers: n, blobs: m, bytes: k, within_limits?: true, limits: %{...}}`, checked
in tests against the caps and exposed for monitoring. Small, and it converts
"we have limits" into "here is the bound, recompute it yourself" — which is what
lets an operator answer "how many participants can this instance actually
support" without reading the GenServer.

**Cost:** S. **First step:** the pure function + a property test over
`n ∈ 1..512`.

---

### D-9. Worst-case, not average-case, budgets on the media path (from `tropical-types`)

`tropical-types` uses max-plus so that composition yields *worst-case* bounds
(`max ≤ sum`, with `tropical_grade_le_sequentialTotal` proved). Its README also
notes a no-go theorem — evidence that the repo's authors will publish a negative
result about their own estate.

Burble's headline number is `<10ms` and it is marked "target, not benchmarked"
(ADR-0007, issue #52). Per-frame work composes as encode + encrypt + forward +
jitter-buffer, so the honest composed bound is a **sum**, while the number
people quote (`<10ms`) reads like a max.

**Proposal.** When the latency work happens, state the bound in the tropical
form: per-stage worst-case budget, composed as a sum, with the max over stages
shown separately as the critical path. It costs nothing to phrase it correctly
now, and prevents a benchmark that measures the happy path from being quoted as
a guarantee.

**Cost:** S (wording/spec), M (benchmark). **First step:** reword the README
claim to say "stage-wise budget, composed additively; no end-to-end measurement
yet".

---

### D-10. Session-type the key-exchange handshake (from `choreographic-types` + `typell`)

This is the highest-value *research* borrow and the largest piece of work, so it
belongs last. `choreographic-types` projects a global choreography to local
types and proves (for a fragment) that grading commutes with projection;
`typell` aims at session types enforcing "connections always closed, transactions
atomic, handshake order".

ADR-0016 defines a genuine multi-party protocol: `join → register_public_key →
(leader elects) → publish_sealed → peers open → epoch bump on membership change
→ re-seal`. It is currently enforced by clause ordering in
`Burble.Media.E2EE` and by convention in the (unwritten) client.

**Proposal.** Write the global choreography for the key-exchange handshake as a
document (one page, in the ADR), project it to the three roles (leader, follower,
server), and implement the per-role local type as an explicit state machine with
an illegal-transition test. Even without machine-checking, the act of projecting
would surface today's implicit assumptions — for instance that the server may
see `publish_sealed` before `register_public_key` for a late joiner, which
ADR-0016's prose does not settle.

Do **not** attempt the Agda development. The value is in the projection
discipline, not in a proof Burble cannot maintain.

**Cost:** M (doc + state machine + tests). **First step:** the one-page global
choreography.

---

## 3. If only three things are done

1. **D-1** (residue lists) and **D-7** (E2EE levels) — together they fix the
   problem this whole round existed to fix: claims that cannot be checked.
2. **D-4 step 1** (persist the audit log) — `Burble.Moderation` and
   `Burble.Audit` currently promise an audit trail that a log rotation erases.
3. **D-3** (HTTP exposure matrix as a build gate) — cheapest possible way to
   make the API surface reviewable and keep it that way.

---

## 4. Considered and not proposed

Recorded so the survey is visibly a survey and not a wish list.

| Candidate | Why not |
|---|---|
| `secret-types`' noninterference theorem, in Agda, for Burble | Burble has no typed core language to prove it about; the *discipline* (D-2) transfers, the artefact does not. |
| `typell` / `typedqliser` as dependencies | Both are early-stage verification kernels for query languages. Burble's queries are not the risk surface; its handshake and media path are. |
| `typed-wasm`'s Idris2 ABI for the Zig kernels | Interesting, but Burble's kernels are explicitly off the live path (README, "Audio kernels"), so proving their ABI buys little now. |
| `tropical-types`' no-go theorem (`hub_ceiling`) | Concerns Protocol Squisher's interoperability claim, not anything Burble ships. |
| `presswerk`'s feature set | Different domain. Two ideas were still borrowed: the `age`/X25519 storage-at-rest pattern (already Burble's direction) and the **protocol-downgrade ladder that starts from the most secure option** — Burble's `Burble.Media.Privacy` should be checked against that ordering. |
| `checky-monkey` | Registry/validator for userscripts; no analogue in Burble. |
| `residual-evidence-types` | Genuinely interesting for abuse-reporting ("the alternative explanations compatible with an observation") but its own README says no stable API; revisit only if Burble grows an evidence-review workflow. |
| `anytype` | The idea — "pick the resource algebra, get the discipline" — is already how ADR-0016 works (labels + AAD + epochs parameterise the protocol). Nothing to add. |
| `hpm-crypto-rsr` | HMAC-SHA256/RS256 with OpenSSL KATs is a good primitive to reach for *if* Burble adds webhook signature verification. It has not; `Burble.Auth` uses JWT via a library. No change proposed, but noted as the estate's answer when that need appears. |

---

## 5. Two cross-cutting observations

**The repos that are careful are careful in a specific way.** `absolute-zero`
ships residue lists, `echo-types` keeps a retraction ledger, `januskey` prints a
CAUTION that its proofs are pending, `anytype` renamed itself to stop
over-claiming, `typed-wasm` badges `believe_me: 0`. This is the same discipline
as ADR-0007, applied at the level of individual claims rather than whole
documents. Burble's version of it is D-1 and D-7.

**None of these repos would have prevented the bug this round fixed.** The
E2EE drift was not a type error; it was a server that returned a key while the
README said it didn't. What prevented it — eventually — was reading the code
against the claim. The mechanisms above make that reading cheaper; they do not
replace it.
