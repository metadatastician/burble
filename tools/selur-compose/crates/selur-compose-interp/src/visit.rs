//! Hand-rolled visitor that applies string interpolation to every `String`-
//! typed field in a [`selur_compose_schema::Compose`].
//!
//! We walk the schema manually rather than using a serde round-trip for two
//! reasons:
//!
//! 1. **Span fidelity** — error spans point into original field values, not
//!    into a JSON blob.
//! 2. **Performance** — no intermediate JSON allocation for what is a simple
//!    struct walk.
//!
//! The visitor is deliberately conservative: it only touches fields where
//! interpolation is semantically correct.  Specifically, `PathBuf` fields
//! (contexts, dockerfiles, env_file paths) are intentionally **not**
//! interpolated — they are resolved by the planner after the compose file is
//! located on disk.

use selur_compose_schema::{
    Build, Compose, Config, ConfigRef, DependsOn, EnvMap as SchemaEnvMap, Healthcheck,
    HealthcheckTest, MountSpec, Network, NetworkMode, Project, Secret, SecretRef, Service,
    StringOrList, Volume,
};
use std::collections::BTreeMap;

use crate::{
    env::EnvMap,
    error::InterpError,
    expander::expand,
};

// ---------------------------------------------------------------------------
// Public entry
// ---------------------------------------------------------------------------

/// Walk `compose` and interpolate every `String` field against `env`.
///
/// Returns a new, owned `Compose` with all variable references resolved.
pub fn visit_compose(compose: Compose, env: &EnvMap) -> Result<Compose, InterpError> {
    Ok(Compose {
        project: compose.project.map(|p| visit_project(p, env)).transpose()?,
        services: compose
            .services
            .into_iter()
            .map(|(k, v)| Ok((k, visit_service(v, env)?)))
            .collect::<Result<BTreeMap<_, _>, InterpError>>()?,
        networks: compose
            .networks
            .into_iter()
            .map(|(k, v)| Ok((k, visit_network(v, env)?)))
            .collect::<Result<BTreeMap<_, _>, InterpError>>()?,
        volumes: compose
            .volumes
            .into_iter()
            .map(|(k, v)| Ok((k, visit_volume(v, env)?)))
            .collect::<Result<BTreeMap<_, _>, InterpError>>()?,
        secrets: compose
            .secrets
            .into_iter()
            .map(|(k, v)| Ok((k, visit_secret(v, env)?)))
            .collect::<Result<BTreeMap<_, _>, InterpError>>()?,
        configs: compose
            .configs
            .into_iter()
            .map(|(k, v)| Ok((k, visit_config_def(v, env)?)))
            .collect::<Result<BTreeMap<_, _>, InterpError>>()?,
        // Extension tables (`x-*`) are raw toml::Value — we do not interpolate
        // inside them.  They are opaque to v0.1.
        extensions: compose.extensions,
    })
}

// ---------------------------------------------------------------------------
// Per-type visitors
// ---------------------------------------------------------------------------

fn visit_project(p: Project, env: &EnvMap) -> Result<Project, InterpError> {
    Ok(Project { name: expand(&p.name, env)? })
}

fn visit_service(svc: Service, env: &EnvMap) -> Result<Service, InterpError> {
    Ok(Service {
        image: svc.image.map(|s| expand(&s, env)).transpose()?,
        build: svc.build.map(|b| visit_build(b, env)).transpose()?,
        command: svc.command.map(|c| visit_string_or_list(c, env)).transpose()?,
        entrypoint: svc.entrypoint.map(|e| visit_string_or_list(e, env)).transpose()?,
        environment: visit_env_map(svc.environment, env)?,
        // env_file paths are not interpolated (filesystem paths resolved by planner).
        env_file: svc.env_file,
        // Port strings — left as-is; port numbers rarely contain variables.
        ports: svc.ports,
        volumes: svc
            .volumes
            .into_iter()
            .map(|m| visit_mount(m, env))
            .collect::<Result<Vec<_>, _>>()?,
        networks: svc
            .networks
            .into_iter()
            .map(|n| expand(&n, env))
            .collect::<Result<Vec<_>, _>>()?,
        network_mode: svc.network_mode.map(|nm| visit_network_mode(nm, env)).transpose()?,
        depends_on: visit_depends_on(svc.depends_on, env)?,
        healthcheck: svc.healthcheck.map(|h| visit_healthcheck(h, env)).transpose()?,
        restart: svc.restart,
        profiles: svc
            .profiles
            .into_iter()
            .map(|p| expand(&p, env))
            .collect::<Result<Vec<_>, _>>()?,
        secrets: svc
            .secrets
            .into_iter()
            .map(|s| visit_secret_ref(s, env))
            .collect::<Result<Vec<_>, _>>()?,
        configs: svc
            .configs
            .into_iter()
            .map(|c| visit_config_ref(c, env))
            .collect::<Result<Vec<_>, _>>()?,
        user: svc.user.map(|s| expand(&s, env)).transpose()?,
        working_dir: svc.working_dir.map(|s| expand(&s, env)).transpose()?,
        hostname: svc.hostname.map(|s| expand(&s, env)).transpose()?,
        cap_add: svc
            .cap_add
            .into_iter()
            .map(|s| expand(&s, env))
            .collect::<Result<Vec<_>, _>>()?,
        cap_drop: svc
            .cap_drop
            .into_iter()
            .map(|s| expand(&s, env))
            .collect::<Result<Vec<_>, _>>()?,
        init: svc.init,
        stop_signal: svc.stop_signal.map(|s| expand(&s, env)).transpose()?,
        stop_grace_period: svc.stop_grace_period,
    })
}

fn visit_build(b: Build, env: &EnvMap) -> Result<Build, InterpError> {
    Ok(Build {
        // context and dockerfile are PathBuf — not interpolated (filesystem paths).
        context: b.context,
        dockerfile: b.dockerfile,
        args: b
            .args
            .into_iter()
            .map(|(k, v)| Ok((k, expand(&v, env)?)))
            .collect::<Result<BTreeMap<_, _>, InterpError>>()?,
        target: b.target.map(|s| expand(&s, env)).transpose()?,
        labels: b
            .labels
            .into_iter()
            .map(|(k, v)| Ok((k, expand(&v, env)?)))
            .collect::<Result<BTreeMap<_, _>, InterpError>>()?,
        no_cache: b.no_cache,
    })
}

fn visit_string_or_list(sol: StringOrList, env: &EnvMap) -> Result<StringOrList, InterpError> {
    match sol {
        StringOrList::String(s) => Ok(StringOrList::String(expand(&s, env)?)),
        StringOrList::List(items) => {
            let expanded = items
                .into_iter()
                .map(|s| expand(&s, env))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(StringOrList::List(expanded))
        }
    }
}

fn visit_env_map(em: SchemaEnvMap, env: &EnvMap) -> Result<SchemaEnvMap, InterpError> {
    match em {
        SchemaEnvMap::Empty => Ok(SchemaEnvMap::Empty),
        SchemaEnvMap::List(items) => {
            let expanded = items
                .into_iter()
                .map(|s| expand(&s, env))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(SchemaEnvMap::List(expanded))
        }
        SchemaEnvMap::Map(map) => {
            let expanded = map
                .into_iter()
                .map(|(k, v)| {
                    let new_v = v.map(|s| expand(&s, env)).transpose()?;
                    Ok((k, new_v))
                })
                .collect::<Result<BTreeMap<_, _>, InterpError>>()?;
            Ok(SchemaEnvMap::Map(expanded))
        }
    }
}

fn visit_mount(m: MountSpec, env: &EnvMap) -> Result<MountSpec, InterpError> {
    match m {
        MountSpec::Short(s) => Ok(MountSpec::Short(expand(&s, env)?)),
        // Long-form mounts: PathBuf fields (source, target) are not interpolated.
        MountSpec::Long(l) => Ok(MountSpec::Long(l)),
    }
}

fn visit_network_mode(nm: NetworkMode, env: &EnvMap) -> Result<NetworkMode, InterpError> {
    match nm {
        NetworkMode::Custom(s) => Ok(NetworkMode::Custom(expand(&s, env)?)),
        NetworkMode::Container(s) => Ok(NetworkMode::Container(expand(&s, env)?)),
        other => Ok(other),
    }
}

fn visit_depends_on(d: DependsOn, _env: &EnvMap) -> Result<DependsOn, InterpError> {
    // Service names in depends_on are identifiers, not user-facing strings.
    // They are validated at plan time; we pass them through unchanged.
    Ok(d)
}

fn visit_healthcheck(h: Healthcheck, env: &EnvMap) -> Result<Healthcheck, InterpError> {
    Ok(Healthcheck {
        test: visit_healthcheck_test(h.test, env)?,
        interval: h.interval,
        timeout: h.timeout,
        retries: h.retries,
        start_period: h.start_period,
        disable: h.disable,
    })
}

fn visit_healthcheck_test(t: HealthcheckTest, env: &EnvMap) -> Result<HealthcheckTest, InterpError> {
    match t {
        HealthcheckTest::Shell(s) => Ok(HealthcheckTest::Shell(expand(&s, env)?)),
        HealthcheckTest::Exec(items) => {
            let expanded = items
                .into_iter()
                .map(|s| expand(&s, env))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(HealthcheckTest::Exec(expanded))
        }
    }
}

fn visit_network(n: Network, env: &EnvMap) -> Result<Network, InterpError> {
    use selur_compose_schema::networks::Network as N;
    Ok(N {
        driver: n.driver.map(|s| expand(&s, env)).transpose()?,
        driver_opts: n
            .driver_opts
            .into_iter()
            .map(|(k, v)| Ok((k, expand(&v, env)?)))
            .collect::<Result<BTreeMap<_, _>, InterpError>>()?,
        external: n.external,
        name: n.name.map(|s| expand(&s, env)).transpose()?,
        labels: n
            .labels
            .into_iter()
            .map(|(k, v)| Ok((k, expand(&v, env)?)))
            .collect::<Result<BTreeMap<_, _>, InterpError>>()?,
        ipam: n.ipam,
        internal: n.internal,
    })
}

fn visit_volume(v: Volume, env: &EnvMap) -> Result<Volume, InterpError> {
    Ok(Volume {
        driver: v.driver.map(|s| expand(&s, env)).transpose()?,
        driver_opts: v
            .driver_opts
            .into_iter()
            .map(|(k, val)| Ok((k, expand(&val, env)?)))
            .collect::<Result<BTreeMap<_, _>, InterpError>>()?,
        external: v.external,
        name: v.name.map(|s| expand(&s, env)).transpose()?,
        labels: v
            .labels
            .into_iter()
            .map(|(k, val)| Ok((k, expand(&val, env)?)))
            .collect::<Result<BTreeMap<_, _>, InterpError>>()?,
    })
}

fn visit_secret(s: Secret, env: &EnvMap) -> Result<Secret, InterpError> {
    Ok(Secret {
        // `file` is a PathBuf — not interpolated.
        file: s.file,
        external: s.external,
        name: s.name.map(|n| expand(&n, env)).transpose()?,
    })
}

fn visit_config_def(c: Config, env: &EnvMap) -> Result<Config, InterpError> {
    Ok(Config {
        file: c.file,
        external: c.external,
        name: c.name.map(|n| expand(&n, env)).transpose()?,
    })
}

fn visit_secret_ref(sr: SecretRef, env: &EnvMap) -> Result<SecretRef, InterpError> {
    use selur_compose_schema::secrets::SecretRefLong;
    match sr {
        SecretRef::Name(n) => Ok(SecretRef::Name(expand(&n, env)?)),
        SecretRef::Long(l) => Ok(SecretRef::Long(SecretRefLong {
            source: expand(&l.source, env)?,
            // `target` is a PathBuf — not interpolated.
            target: l.target,
            uid: l.uid.map(|s| expand(&s, env)).transpose()?,
            gid: l.gid.map(|s| expand(&s, env)).transpose()?,
            mode: l.mode,
        })),
    }
}

fn visit_config_ref(cr: ConfigRef, env: &EnvMap) -> Result<ConfigRef, InterpError> {
    use selur_compose_schema::secrets::ConfigRefLong;
    match cr {
        ConfigRef::Name(n) => Ok(ConfigRef::Name(expand(&n, env)?)),
        ConfigRef::Long(l) => Ok(ConfigRef::Long(ConfigRefLong {
            source: expand(&l.source, env)?,
            target: l.target,
            uid: l.uid.map(|s| expand(&s, env)).transpose()?,
            gid: l.gid.map(|s| expand(&s, env)).transpose()?,
            mode: l.mode,
        })),
    }
}
