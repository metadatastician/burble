# SPDX-License-Identifier: MPL-2.0
# Dust — exnovation / code-removal runner
#
# Pairs with: Dustfile.a2ml (same directory)
# Verb:       dust
# Semantics:  exnovation. Identifies code, docs, files, dependencies that are
#             candidates for REMOVAL. Advisory by default; can be flipped to
#             active delete via `contractile dust sweep --apply`.
# CLI:        `contractile dust find`   → list removal candidates
#             `contractile dust sweep`  → dry-run removals
#             `contractile dust sweep --apply` → actually delete (gated)
#
# Anything else in this directory is human-only notes/archive; machines ignore.
#
# Base: ../_base.ncl provides pedigree_schema, run_defaults, probe_schema.
# See: docs/CONTRACTILE-SPEC.adoc

let base = import "../_base.ncl" in

{
  pedigree = base.pedigree_schema & {
    contractile_verb = "dust",
    semantics = "exnovation / removal",
    security = {
      leash = 'Kennel,
      trust_level = "proposes deletion; --apply required to execute",
      allow_network = false,
      allow_filesystem_write = true,      # --apply mode writes (deletes)
      allow_subprocess = true,
      destructive_mode_requires_flag = "--apply",
    },
    metadata = {
      name = "dust-runner",
      version = "1.0.0",
      description = "Identifies and optionally removes exnovation targets listed in Dustfile.a2ml. Destructive mode gated behind --apply.",
      paired_xfile = "Dustfile.a2ml",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
  },

  schema = {
    removal_candidates
      | Array {
          id | String,
          description | String,
          target | String,                 # file / path / symbol / dep name
          reason | String,                 # why it's a removal candidate
          # TODO: migrate to base.probe_schema (structured probe) when CLI supports it
          probe | String | optional,       # command that confirms it's still removable
          # dust has a non-standard status progression (no 'verified):
          #   'declared → 'proposed → 'approved → 'removed
          status | [| 'declared, 'proposed, 'approved, 'removed |] | default = 'declared,
          approver | String | optional,    # who signed off (for 'approved / 'removed)
          notes | String | optional,
        },
  },

  # Runner behaviour — inherits from base.run_defaults.
  # dust is advisory; apply_requires_approval is dust-specific.
  run = base.run_defaults & {
    on_any_fail = "continue-with-warnings",
    report_format = "a2ml",
    emit_summary = true,
    apply_requires_approval = true,       # only 'approved items get swept, even with --apply
  },
}
