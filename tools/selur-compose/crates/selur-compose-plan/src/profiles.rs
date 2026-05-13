//! Profile-based service filtering.
//!
//! In compose, services can be tagged with a `profiles` list.  A service is
//! *active* if:
//!
//! 1. It has no `profiles` entry (always included), **or**
//! 2. At least one of its profiles appears in the caller's enabled-profile set.
//!
//! # Example
//!
//! ```toml
//! [services.db]
//! image = "postgres:16"
//! # no profiles — always active
//!
//! [services.test-seed]
//! image = "myapp-seed:latest"
//! profiles = ["test"]
//! # only active when --profile test is passed
//! ```

use std::collections::BTreeMap;

use selur_compose_schema::{Compose, Service};

use crate::PlanError;

/// Return a filtered map of services that are active under `enabled_profiles`.
///
/// A service with an empty `profiles` list is always included.
/// A service whose `profiles` list is non-empty is included only if the
/// intersection with `enabled_profiles` is non-empty.
///
/// # Errors
///
/// Returns [`PlanError::UnknownProfile`] if a profile listed in
/// `enabled_profiles` is not referenced by any service in `compose`.
/// This surfaces likely typos at plan time rather than silently ignoring them.
pub fn filter_services<'a>(
    compose: &'a Compose,
    enabled_profiles: &[String],
) -> Result<BTreeMap<&'a str, &'a Service>, PlanError> {
    // Collect all profile names referenced anywhere in the compose file.
    let all_profiles: std::collections::HashSet<&str> = compose
        .services
        .values()
        .flat_map(|svc| svc.profiles.iter().map(|p| p.as_str()))
        .collect();

    // Validate enabled profiles.
    for prof in enabled_profiles {
        if !all_profiles.contains(prof.as_str()) {
            // If no service defines profiles at all and the user passed one,
            // that is still an error — the profile name is unrecognised.
            return Err(PlanError::UnknownProfile {
                profile: prof.clone(),
            });
        }
    }

    let enabled_set: std::collections::HashSet<&str> =
        enabled_profiles.iter().map(|s| s.as_str()).collect();

    let filtered: BTreeMap<&str, &Service> = compose
        .services
        .iter()
        .filter_map(|(name, svc)| {
            if svc.profiles.is_empty() {
                // No profiles — always active.
                Some((name.as_str(), svc))
            } else if svc.profiles.iter().any(|p| enabled_set.contains(p.as_str())) {
                // At least one profile matches.
                Some((name.as_str(), svc))
            } else {
                None
            }
        })
        .collect();

    Ok(filtered)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(toml: &str) -> Compose {
        selur_compose_schema::parse_str(toml, None).unwrap()
    }

    #[test]
    fn no_profiles_always_included() {
        let compose = parse(
            r#"
            [services.app]
            image = "alpine"
            "#,
        );
        let active = filter_services(&compose, &[]).unwrap();
        assert!(active.contains_key("app"), "app has no profiles, must be included");
    }

    #[test]
    fn profile_tagged_excluded_without_flag() {
        let compose = parse(
            r#"
            [services.app]
            image = "alpine"

            [services.seed]
            image = "seed:latest"
            profiles = ["test"]
            "#,
        );
        let active = filter_services(&compose, &[]).unwrap();
        assert!(active.contains_key("app"), "app always included");
        assert!(!active.contains_key("seed"), "seed excluded without --profile test");
    }

    #[test]
    fn profile_tagged_included_with_flag() {
        let compose = parse(
            r#"
            [services.app]
            image = "alpine"

            [services.seed]
            image = "seed:latest"
            profiles = ["test"]
            "#,
        );
        let active = filter_services(&compose, &["test".to_string()]).unwrap();
        assert!(active.contains_key("app"));
        assert!(active.contains_key("seed"), "seed included with --profile test");
    }

    #[test]
    fn unknown_profile_returns_error() {
        let compose = parse(
            r#"
            [services.app]
            image = "alpine"
            profiles = ["dev"]
            "#,
        );
        let result = filter_services(&compose, &["nonexistent".to_string()]);
        assert!(
            matches!(result, Err(PlanError::UnknownProfile { profile }) if profile == "nonexistent"),
            "expected UnknownProfile error"
        );
    }

    #[test]
    fn multiple_profiles_any_match_includes() {
        let compose = parse(
            r#"
            [services.app]
            image = "alpine"
            profiles = ["dev", "staging"]
            "#,
        );
        // Only "dev" is enabled; service has both "dev" and "staging".
        let active = filter_services(&compose, &["dev".to_string()]).unwrap();
        assert!(active.contains_key("app"), "any profile match is sufficient");
    }

    #[test]
    fn empty_compose_no_profiles_ok() {
        // A compose file with no services at all — no profile validation errors.
        let compose = parse(r#""#);
        // Enabling a nonexistent profile against an empty compose should fail
        // because we cannot find the profile in any service.
        // Actually: if there are zero services, all_profiles is empty, and
        // any enabled profile is unknown.  This is intentional.
        let result = filter_services(&compose, &["dev".to_string()]);
        assert!(matches!(result, Err(PlanError::UnknownProfile { .. })));
    }

    #[test]
    fn no_enabled_profiles_no_error() {
        let compose = parse(r#""#);
        let active = filter_services(&compose, &[]).unwrap();
        assert!(active.is_empty());
    }
}
