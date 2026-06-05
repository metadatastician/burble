# SPDX-License-Identifier: MPL-2.0
# Trust — security + safe-hacking runner
#
# Pairs with: Trustfile.a2ml (same directory)
# Verb:       trust
# Semantics:  integrity / provenance / security verification PLUS a declared
#             "safe hacking + testing" section — authorised offensive probes
#             (pen-test harness runs, chaos-engineering probes) scoped to the
#             repo under test, NEVER touching external systems.
# CLI:        `contractile trust verify` → run all verifications (read-only)
#             `contractile trust probe`  → run declared safe-hacking probes
#
# Anything else in this directory is human-only notes/archive; machines ignore.
#
# Base: ../_base.ncl provides pedigree_schema, run_defaults, probe_schema.
# See: docs/CONTRACTILE-SPEC.adoc

let base = import "../_base.ncl" in

{
  pedigree = base.pedigree_schema & {
    contractile_verb = "trust",
    semantics = "security + provenance + safe-hacking",
    security = {
      leash = 'Kennel,
      trust_level = "verification + authorised-probe",
      allow_network = false,            # verifications are offline by default
      allow_filesystem_write = false,   # trust writes NOTHING
      allow_subprocess = true,
      authorised_probes_only = true,    # probe section must explicitly list allowed targets
    },
    metadata = {
      name = "trust-runner",
      version = "1.0.0",
      description = "Security + provenance verifications plus authorised safe-hacking probes. All probes are scoped to the repo under test; never hits external systems.",
      paired_xfile = "Trustfile.a2ml",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
  },

  schema = {
    verifications
      | Array {
          id | String,
          description | String,
          # TODO: migrate to base.probe_schema (structured probe) when CLI supports it
          probe | String,                 # read-only; exit 0 = pass
          # status_core values: 'declared, 'verified, 'failing
          status | [| 'declared, 'verified, 'failing |] | default = 'declared,
          # trust uses all four severity levels (from base.severity_core)
          severity | [| 'critical, 'high, 'medium, 'low |] | default = 'high,
          notes | String | optional,
        },

    # Safe-hacking + testing section (added 2026-04-17 per user direction).
    # Each probe here is an ACTIVELY EXECUTED test — fuzz runs, chaos probes,
    # auth-bypass attempts, injection tests. All scoped to the current repo.
    safe_hacking
      | {
          scope | String,                 # e.g. "this-repo-only" / "localhost"
          allowed_probe_classes
            | Array [| 'fuzz, 'property_test, 'chaos, 'auth_bypass, 'injection, 'timing |]
            | default = [],
          probes
            | Array {
                id | String,
                class | [| 'fuzz, 'property_test, 'chaos, 'auth_bypass, 'injection, 'timing |],
                description | String,
                # TODO: migrate to base.probe_schema (structured probe) when CLI supports it
                probe | String,             # command to run the probe
                expected_outcome | [| 'probe_blocks_attempt, 'probe_finds_no_issue |],
                timeout_seconds | Number | default = 300,
                notes | String | optional,
              }
            | default = [],
        }
      | default = { scope = "this-repo-only", allowed_probe_classes = [], probes = [] },
  },

  # Runner behaviour — inherits from base.run_defaults.
  # trust has an extra field for unexpected safe-hacking outcomes.
  run = base.run_defaults & {
    on_any_fail = "exit-nonzero",       # hard gate on verifications
    safe_hacking_on_unexpected_outcome = "exit-nonzero",  # probe found what it shouldn't = block
    report_format = "a2ml",
    emit_summary = true,
  },
}
