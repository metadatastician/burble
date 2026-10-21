K9!
# SPDX-License-Identifier: MPL-2.0
# Example Hunt-level K9 component: Repository setup automation
# Security Level: Hunt (full execution with Just recipes)
# ⚠️ SIGNATURE REQUIRED - DO NOT RUN WITHOUT VERIFICATION

{
  pedigree = {
    schema_version = "1.0.0",
    component_type = "repository-setup",
    security = {
      leash = 'Hunt,
      trust_level = "full-system-access",
      allow_network = true,
      allow_filesystem_write = true,
      allow_subprocess = true,
      signature_required = true,
      # §8.4 / K9-S007 — the flags above are a REQUEST, not a grant. A host
      # enforces the grant, so an example that leaves it out teaches the exact
      # mistake the rule exists to catch: three capabilities asked for, none
      # paid for.
      capabilities = ["net.fetch", "fs.write", "process.spawn"],
    },
    metadata = {
      name = "setup-repo",
      version = "1.0.0",
      description = "Automated repository setup with RSR standards",
      author = "{{AUTHOR}} <{{AUTHOR_EMAIL}}>",
    },
    warnings = [
      "This component has full system access",
      "Only run from trusted sources with verified signatures",
      "Review Just recipes before execution",
      "Use dry-run mode first: ./must --dry-run run setup-repo.k9.ncl",
    ],
    # §6.5 / K9-S010 — 'Hunt must describe what full access is for. An empty
    # list is a claim of system access with nothing to review.
    side_effects = [
      "creates directories and files in the working tree",
      "runs git init and writes git config",
      "fetches the licence text over the network",
      "executes shell commands from the recipes block",
    ],
    # §10 / K9-S009 — presence only. This block proves the file carries a
    # claim; it does not make the claim true. Verification is K9-C001, and a
    # host that has not run a verifier must report 'Present_Unverified, which
    # never authorises 'Hunt.
    signature = {
      algorithm = "Ed25519",
      public_key = "{{SIGNING_PUBLIC_KEY}}",
      signature = "{{SIGNATURE}}",
      payload_hash = "{{SHA256_OF_BODY}}",
      signed_at = "{{SIGNED_AT_ISO8601}}",
      key_id = "primary",
    },
  },

  # Configuration with contracts
  config = {
    repo_name
      | String
      | std.string.NonEmpty
      = "my-new-repo",

    repo_type
      | [| 'Library, 'Application, 'Tool, 'Specification |]
      = 'Application,

    primary_language
      | String
      | std.string.NonEmpty
      = "rust",

    # RSR compliance features to enable
    features = {
      checkpoint_files | Bool = true,  # STATE.a2ml, ECOSYSTEM.a2ml, META.a2ml
      security_workflows | Bool = true,  # CodeQL, Scorecard, etc.
      quality_checks | Bool = true,  # Linting, formatting
      mirroring | Bool = false,  # GitLab/Bitbucket mirrors
    },

    # Git configuration
    git = {
      default_branch = "main",
      initial_commit | Bool = true,
      remote_url | String = "",
    },
  },

  # Just recipes for execution
  # These run when: ./must run setup-repo.k9.ncl
  recipes = {
    # Main entry point
    default = {
      recipe = "setup",
      description = "Set up RSR-compliant repository",
    },

    # Individual setup tasks
    setup = {
      dependencies = ["check-env", "create-structure", "init-git", "setup-workflows"],
      commands = [
        "echo '✅ Repository setup complete!'",
        "echo 'Run: git status to see changes'",
      ],
    },

    "check-env" = {
      description = "Verify required tools are installed",
      commands = [
        "command -v git || (echo 'ERROR: git not found' && exit 1)",
        "command -v just || (echo 'ERROR: just not found' && exit 1)",
        "command -v nickel || (echo 'ERROR: nickel not found' && exit 1)",
        "echo '✓ All required tools present'",
      ],
    },

    "create-structure" = {
      description = "Create RSR directory structure",
      commands = [
        "mkdir -p src/ docs/ tests/ scripts/",
        "mkdir -p .github/workflows/",
        "mkdir -p .machine_readable/contractiles/self-validating/",
        "echo '✓ Directory structure created'",
      ],
    },

    "init-git" = {
      description = "Initialize Git repository",
      commands = [
        "git init -b %{config.git.default_branch}",
        "git config user.name '{{AUTHOR}}'",
        "git config user.email '{{AUTHOR_EMAIL}}'",
        "echo '✓ Git initialized'",
      ],
    },

    "setup-workflows" = {
      description = "Add RSR-compliant workflows",
      commands = [
        # This would copy workflow templates
        # In a real implementation, would fetch from rsr-template-repo
        "echo '✓ Workflows configured'",
      ],
    },

    "create-checkpoint-files" = {
      description = "Create STATE.a2ml, ECOSYSTEM.a2ml, META.a2ml",
      commands = [
        "echo '(state (version \"1.0.0\") (project \"%{config.repo_name}\"))' > STATE.a2ml",
        "echo '(ecosystem (version \"1.0.0\") (name \"%{config.repo_name}\"))' > ECOSYSTEM.a2ml",
        "echo '(meta (version \"1.0.0\") (project \"%{config.repo_name}\"))' > META.a2ml",
        "echo '✓ Checkpoint files created'",
      ],
    },

    "add-license" = {
      description = "Add PMPL-1.0 license",
      commands = [
        "curl -sL https://raw.githubusercontent.com/hyperpolymath/pmpl/main/LICENSE -o LICENSE",
        "echo '✓ License added'",
      ],
    },

    "add-readme" = {
      description = "Create README.adoc from template",
      commands = [
        "echo '= %{config.repo_name}' > README.adoc",
        "echo '' >> README.adoc",
        "echo 'Part of the Hyperpolymath ecosystem.' >> README.adoc",
        "echo '✓ README created'",
      ],
    },

    clean = {
      description = "Remove generated files (careful!)",
      commands = [
        "echo '⚠️  This will delete all generated files'",
        "echo 'Press Ctrl+C to cancel, or wait 5 seconds...'",
        "sleep 5",
        "rm -f STATE.a2ml ECOSYSTEM.a2ml META.a2ml",
        "echo '✓ Cleaned'",
      ],
    },
  },

  # Validation (Yard-level checks before Hunt execution)
  validation = {
    check_repo_name = std.string.length config.repo_name > 0,
    check_language = std.string.length config.primary_language > 0,
  },
}
