//! Property-based fuzz tests for the schema parser.
//!
//! Generates arbitrary `Compose`-shaped structs and verifies that:
//! 1. They serialise to TOML without panicking.
//! 2. If serialisation succeeds, parsing the result is identity (round-trip).
//!
//! Run count is 256 in CI; 10000 in nightly (set `PROPTEST_CASES=10000`).

use proptest::prelude::*;
use selur_compose_schema::{
    depends_on::{DependsCondition, DependsOn, DependsOnSpec},
    healthcheck::{Healthcheck, HealthcheckTest},
    networks::{Network, NetworkMode},
    services::{EnvMap, RestartPolicy, Service},
    volumes::Volume,
    Compose, Project,
};
use std::collections::BTreeMap;

// ---------------------------------------------------------------------------
// Prop strategies
// ---------------------------------------------------------------------------

fn arb_string() -> impl Strategy<Value = String> {
    "[a-zA-Z0-9_\\-]{1,32}".prop_map(|s| s)
}

fn arb_restart_policy() -> impl Strategy<Value = RestartPolicy> {
    prop_oneof![
        Just(RestartPolicy::No),
        Just(RestartPolicy::Always),
        Just(RestartPolicy::OnFailure),
        Just(RestartPolicy::UnlessStopped),
    ]
}

fn arb_depends_on() -> impl Strategy<Value = DependsOn> {
    prop_oneof![
        Just(DependsOn::Empty),
        prop::collection::vec(arb_string(), 0..4).prop_map(|v| {
            if v.is_empty() {
                DependsOn::Empty
            } else {
                DependsOn::List(v)
            }
        }),
    ]
}

fn arb_healthcheck_test() -> impl Strategy<Value = HealthcheckTest> {
    prop_oneof![
        arb_string().prop_map(HealthcheckTest::Shell),
        prop::collection::vec(arb_string(), 1..4)
            .prop_map(HealthcheckTest::Exec),
    ]
}

fn arb_healthcheck() -> impl Strategy<Value = Healthcheck> {
    arb_healthcheck_test().prop_map(|test| Healthcheck {
        test,
        interval:     None,
        timeout:      None,
        retries:      None,
        start_period: None,
        disable:      false,
    })
}

fn arb_env_map() -> impl Strategy<Value = EnvMap> {
    prop_oneof![
        Just(EnvMap::Empty),
        prop::collection::vec(
            arb_string().prop_map(|k| format!("{k}=value")),
            0..4
        )
        .prop_map(|v| if v.is_empty() {
            EnvMap::Empty
        } else {
            EnvMap::List(v)
        }),
    ]
}

fn arb_service(dep_names: Vec<String>) -> impl Strategy<Value = Service> {
    let dep_names = dep_names.clone();
    (
        arb_restart_policy(),
        arb_env_map(),
        proptest::option::of(arb_healthcheck()),
        prop::bool::ANY,
    )
        .prop_map(move |(restart, environment, healthcheck, use_dep)| {
            let depends_on = if use_dep && !dep_names.is_empty() {
                DependsOn::List(dep_names.clone())
            } else {
                DependsOn::Empty
            };
            Service {
                image:              Some("nginx:latest".to_owned()),
                build:              None,
                command:            None,
                entrypoint:         None,
                environment,
                env_file:           vec![],
                ports:              vec![],
                volumes:            vec![],
                networks:           vec![],
                network_mode:       None,
                depends_on,
                healthcheck,
                restart,
                profiles:           vec![],
                secrets:            vec![],
                configs:            vec![],
                user:               None,
                working_dir:        None,
                hostname:           None,
                cap_add:            vec![],
                cap_drop:           vec![],
                init:               None,
                stop_signal:        None,
                stop_grace_period:  None,
            }
        })
}

fn arb_compose() -> impl Strategy<Value = Compose> {
    prop::collection::vec(arb_string(), 1..4).prop_flat_map(|names| {
        let all_names = names.clone();
        let service_strats: Vec<_> = names
            .iter()
            .map(|_| arb_service(all_names.clone()))
            .collect();
        service_strats.prop_map(move |svcs| {
            let services: BTreeMap<String, Service> = names
                .iter()
                .cloned()
                .zip(svcs.into_iter())
                .collect();
            Compose {
                project:    Some(Project { name: "fuzz-project".to_owned() }),
                services,
                networks:   BTreeMap::new(),
                volumes:    BTreeMap::new(),
                secrets:    BTreeMap::new(),
                configs:    BTreeMap::new(),
                extensions: BTreeMap::new(),
            }
        })
    })
}

// ---------------------------------------------------------------------------
// Property test
// ---------------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    #[test]
    fn compose_round_trips_through_toml(compose in arb_compose()) {
        // Serialise to TOML — this must not panic
        let Ok(toml_str) = toml::to_string(&compose) else {
            // If serialisation fails that's a bug in our serialiser, but
            // proptest::assume! would silently skip — we want a hard failure.
            panic!("serialise failed for generated Compose");
        };

        // Parse back
        let parsed = selur_compose_schema::parse_str(
            &toml_str,
            Some(std::path::Path::new("<fuzz>")),
        ).unwrap_or_else(|e| panic!("re-parse failed: {e}\ntoml:\n{toml_str}"));

        // JSON equality
        let j1 = serde_json::to_value(&compose).unwrap();
        let j2 = serde_json::to_value(&parsed).unwrap();
        prop_assert_eq!(j1, j2);
    }
}
