//! Pure argv-composition functions.
//!
//! Each function takes a typed spec and returns the `Vec<String>` argument
//! list to pass to `podman`.  **No I/O is performed here** — the functions
//! are pure and trivially snapshot-testable.
//!
//! # Conventions
//!
//! - The first element is always `"podman"`.
//! - All values are `String`, not `&str`, to simplify caller ownership.

use selur_compose_plan::{BuildSpec, NetworkSpec, RunSpec, VolumeSpec};

// ---------------------------------------------------------------------------
// build_argv
// ---------------------------------------------------------------------------

/// Compose the argv for `podman build`.
///
/// ```text
/// podman build
///   [--no-cache]
///   --tag <tag>
///   [--file <dockerfile>]
///   [--target <stage>]
///   [--build-arg KEY=VAL …]
///   <context>
/// ```
pub fn build_argv(spec: &BuildSpec) -> Vec<String> {
    let mut argv = vec!["podman".to_string(), "build".to_string()];

    if spec.no_cache {
        argv.push("--no-cache".to_string());
    }

    argv.push("--tag".to_string());
    argv.push(spec.tag.clone());

    if let Some(df) = &spec.dockerfile {
        argv.push("--file".to_string());
        argv.push(df.display().to_string());
    }

    if let Some(target) = &spec.target {
        argv.push("--target".to_string());
        argv.push(target.clone());
    }

    for (key, val) in &spec.args {
        argv.push("--build-arg".to_string());
        argv.push(format!("{key}={val}"));
    }

    argv.push(spec.context.display().to_string());

    argv
}

// ---------------------------------------------------------------------------
// pull_argv
// ---------------------------------------------------------------------------

/// Compose the argv for `podman pull`.
///
/// ```text
/// podman pull <image>
/// ```
pub fn pull_argv(image: &str) -> Vec<String> {
    vec!["podman".to_string(), "pull".to_string(), image.to_string()]
}

// ---------------------------------------------------------------------------
// network_create_argv
// ---------------------------------------------------------------------------

/// Compose the argv for `podman network create`.
///
/// ```text
/// podman network create
///   [--driver <driver>]
///   [--label KEY=VAL …]
///   <name>
/// ```
pub fn network_create_argv(spec: &NetworkSpec) -> Vec<String> {
    let mut argv = vec![
        "podman".to_string(),
        "network".to_string(),
        "create".to_string(),
    ];

    if let Some(driver) = &spec.driver {
        argv.push("--driver".to_string());
        argv.push(driver.clone());
    }

    for (key, val) in &spec.labels {
        argv.push("--label".to_string());
        argv.push(format!("{key}={val}"));
    }

    argv.push(spec.name.clone());
    argv
}

// ---------------------------------------------------------------------------
// volume_create_argv
// ---------------------------------------------------------------------------

/// Compose the argv for `podman volume create`.
///
/// ```text
/// podman volume create
///   [--driver <driver>]
///   [--label KEY=VAL …]
///   <name>
/// ```
pub fn volume_create_argv(spec: &VolumeSpec) -> Vec<String> {
    let mut argv = vec![
        "podman".to_string(),
        "volume".to_string(),
        "create".to_string(),
    ];

    if let Some(driver) = &spec.driver {
        argv.push("--driver".to_string());
        argv.push(driver.clone());
    }

    for (key, val) in &spec.labels {
        argv.push("--label".to_string());
        argv.push(format!("{key}={val}"));
    }

    argv.push(spec.name.clone());
    argv
}

// ---------------------------------------------------------------------------
// run_argv
// ---------------------------------------------------------------------------

/// Compose the argv for `podman run --detach`.
///
/// ```text
/// podman run
///   --detach
///   --name <container_name>
///   [--network <net> | --network <mode>]
///   [--restart <policy>]
///   [--env KEY=VAL …]
///   [--volume <mount> …]
///   [--publish <binding> …]
///   [--label KEY=VAL …]
///   [--entrypoint <ep>]
///   <image>
///   [<command args>…]
/// ```
pub fn run_argv(spec: &RunSpec) -> Vec<String> {
    let mut argv = vec![
        "podman".to_string(),
        "run".to_string(),
        "--detach".to_string(),
        "--name".to_string(),
        spec.container_name.clone(),
    ];

    // Network mode or named networks.
    if let Some(mode) = &spec.network_mode {
        argv.push("--network".to_string());
        argv.push(mode.clone());
    } else {
        for net in &spec.networks {
            argv.push("--network".to_string());
            argv.push(net.clone());
        }
    }

    // Restart policy.
    if !spec.restart.is_empty() && spec.restart != "no" {
        argv.push("--restart".to_string());
        argv.push(spec.restart.clone());
    }

    // Environment variables.
    for env in &spec.environment {
        argv.push("--env".to_string());
        argv.push(env.clone());
    }

    // Volume mounts.
    for vol in &spec.volumes {
        argv.push("--volume".to_string());
        argv.push(vol.clone());
    }

    // Port bindings.
    for port in &spec.ports {
        argv.push("--publish".to_string());
        argv.push(port.clone());
    }

    // Labels.
    for (key, val) in &spec.labels {
        argv.push("--label".to_string());
        argv.push(format!("{key}={val}"));
    }

    // Entrypoint (must come before image).
    if let Some(ep) = &spec.entrypoint {
        // podman 5.x accepts a JSON array for --entrypoint.
        let ep_json = serde_json::to_string(ep).unwrap_or_else(|_| ep.join(" "));
        argv.push("--entrypoint".to_string());
        argv.push(ep_json);
    }

    // Image reference.
    argv.push(spec.image.clone());

    // Command arguments (after the image).
    if let Some(cmd) = &spec.command {
        argv.extend(cmd.iter().cloned());
    }

    argv
}

// ---------------------------------------------------------------------------
// stop_argv
// ---------------------------------------------------------------------------

/// Compose the argv for `podman stop`.
///
/// ```text
/// podman stop --time <grace_secs> <container_id>
/// ```
pub fn stop_argv(id: &str, grace_secs: u64) -> Vec<String> {
    vec![
        "podman".to_string(),
        "stop".to_string(),
        "--time".to_string(),
        grace_secs.to_string(),
        id.to_string(),
    ]
}

// ---------------------------------------------------------------------------
// rm_argv
// ---------------------------------------------------------------------------

/// Compose the argv for `podman rm`.
///
/// ```text
/// podman rm [--force] <container_id>
/// ```
pub fn rm_argv(id: &str, force: bool) -> Vec<String> {
    let mut argv = vec!["podman".to_string(), "rm".to_string()];
    if force {
        argv.push("--force".to_string());
    }
    argv.push(id.to_string());
    argv
}

// ---------------------------------------------------------------------------
// inspect_argv
// ---------------------------------------------------------------------------

/// Compose the argv for `podman inspect --format json`.
///
/// ```text
/// podman inspect --format json <container_id>
/// ```
pub fn inspect_argv(id: &str) -> Vec<String> {
    vec![
        "podman".to_string(),
        "inspect".to_string(),
        "--format".to_string(),
        "json".to_string(),
        id.to_string(),
    ]
}

// ---------------------------------------------------------------------------
// healthcheck_run_argv
// ---------------------------------------------------------------------------

/// Compose the argv for `podman healthcheck run`.
///
/// ```text
/// podman healthcheck run <container_id>
/// ```
pub fn healthcheck_run_argv(id: &str) -> Vec<String> {
    vec![
        "podman".to_string(),
        "healthcheck".to_string(),
        "run".to_string(),
        id.to_string(),
    ]
}

// ---------------------------------------------------------------------------
// logs_argv
// ---------------------------------------------------------------------------

/// Compose the argv for `podman logs`.
///
/// ```text
/// podman logs [--follow] --timestamps <container_id>
/// ```
pub fn logs_argv(id: &str, follow: bool) -> Vec<String> {
    let mut argv = vec!["podman".to_string(), "logs".to_string()];
    if follow {
        argv.push("--follow".to_string());
    }
    argv.push("--timestamps".to_string());
    argv.push(id.to_string());
    argv
}

// ---------------------------------------------------------------------------
// ps_argv
// ---------------------------------------------------------------------------

/// Compose the argv for `podman ps --filter label=… --format json`.
///
/// ```text
/// podman ps --all
///           --filter label=io.podman.compose.project=<project>
///           --format json
/// ```
pub fn ps_argv(project: &str) -> Vec<String> {
    vec![
        "podman".to_string(),
        "ps".to_string(),
        "--all".to_string(),
        "--filter".to_string(),
        format!("label=io.podman.compose.project={project}"),
        "--format".to_string(),
        "json".to_string(),
    ]
}

// ---------------------------------------------------------------------------
// network_ls_argv
// ---------------------------------------------------------------------------

/// Compose the argv for `podman network ls --format json`.
pub fn network_ls_argv(project: &str) -> Vec<String> {
    vec![
        "podman".to_string(),
        "network".to_string(),
        "ls".to_string(),
        "--filter".to_string(),
        format!("label=io.podman.compose.project={project}"),
        "--format".to_string(),
        "json".to_string(),
    ]
}

// ---------------------------------------------------------------------------
// volume_ls_argv
// ---------------------------------------------------------------------------

/// Compose the argv for `podman volume ls --format json`.
pub fn volume_ls_argv(project: &str) -> Vec<String> {
    vec![
        "podman".to_string(),
        "volume".to_string(),
        "ls".to_string(),
        "--filter".to_string(),
        format!("label=io.podman.compose.project={project}"),
        "--format".to_string(),
        "json".to_string(),
    ]
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    fn minimal_run_spec() -> RunSpec {
        RunSpec {
            service: "web".to_string(),
            image: "nginx:latest".to_string(),
            container_name: "myproject_web".to_string(),
            environment: vec![],
            ports: vec![],
            volumes: vec![],
            networks: vec!["default".to_string()],
            network_mode: None,
            command: None,
            entrypoint: None,
            restart: "unless-stopped".to_string(),
            labels: {
                let mut m = BTreeMap::new();
                m.insert("io.podman.compose.project".to_string(), "myproject".to_string());
                m.insert("io.podman.compose.service".to_string(), "web".to_string());
                m
            },
        }
    }

    #[test]
    fn test_pull_argv() {
        let argv = pull_argv("nginx:latest");
        assert_eq!(argv, vec!["podman", "pull", "nginx:latest"]);
    }

    #[test]
    fn test_stop_argv() {
        let argv = stop_argv("abc123", 10);
        assert_eq!(argv, vec!["podman", "stop", "--time", "10", "abc123"]);
    }

    #[test]
    fn test_rm_argv_force() {
        let argv = rm_argv("abc123", true);
        assert_eq!(argv, vec!["podman", "rm", "--force", "abc123"]);
    }

    #[test]
    fn test_rm_argv_no_force() {
        let argv = rm_argv("abc123", false);
        assert_eq!(argv, vec!["podman", "rm", "abc123"]);
    }

    #[test]
    fn test_inspect_argv() {
        let argv = inspect_argv("abc123");
        assert_eq!(argv, vec!["podman", "inspect", "--format", "json", "abc123"]);
    }

    #[test]
    fn test_logs_argv_follow() {
        let argv = logs_argv("abc123", true);
        assert_eq!(argv, vec!["podman", "logs", "--follow", "--timestamps", "abc123"]);
    }

    #[test]
    fn test_logs_argv_no_follow() {
        let argv = logs_argv("abc123", false);
        assert_eq!(argv, vec!["podman", "logs", "--timestamps", "abc123"]);
    }

    #[test]
    fn test_ps_argv() {
        let argv = ps_argv("burble");
        assert_eq!(
            argv,
            vec![
                "podman", "ps", "--all",
                "--filter", "label=io.podman.compose.project=burble",
                "--format", "json",
            ]
        );
    }

    #[test]
    fn test_run_argv_basic() {
        let spec = minimal_run_spec();
        let argv = run_argv(&spec);
        assert_eq!(&argv[..4], &["podman", "run", "--detach", "--name"]);
        assert!(argv.contains(&"nginx:latest".to_string()));
        assert!(argv.contains(&"--restart".to_string()));
        assert!(argv.contains(&"unless-stopped".to_string()));
    }

    #[test]
    fn test_run_argv_with_ports_and_volumes() {
        let mut spec = minimal_run_spec();
        spec.ports = vec!["4020:80".to_string()];
        spec.volumes = vec!["data:/data".to_string()];
        spec.environment = vec!["FOO=bar".to_string()];

        let argv = run_argv(&spec);
        assert!(argv.contains(&"--publish".to_string()));
        assert!(argv.contains(&"4020:80".to_string()));
        assert!(argv.contains(&"--volume".to_string()));
        assert!(argv.contains(&"data:/data".to_string()));
        assert!(argv.contains(&"--env".to_string()));
        assert!(argv.contains(&"FOO=bar".to_string()));
    }

    #[test]
    fn test_run_argv_host_network_mode() {
        let mut spec = minimal_run_spec();
        spec.network_mode = Some("host".to_string());
        spec.networks = vec![];

        let argv = run_argv(&spec);
        let net_positions: Vec<usize> = argv
            .iter()
            .enumerate()
            .filter(|(_, a)| a.as_str() == "--network")
            .map(|(i, _)| i)
            .collect();
        assert_eq!(net_positions.len(), 1, "exactly one --network flag");
        assert_eq!(argv[net_positions[0] + 1], "host");
    }

    #[test]
    fn test_run_argv_with_command_and_entrypoint() {
        let mut spec = minimal_run_spec();
        spec.entrypoint = Some(vec!["/bin/sh".to_string(), "-c".to_string()]);
        spec.command = Some(vec!["echo hello".to_string()]);
        let argv = run_argv(&spec);

        let img_pos = argv.iter().position(|a| a == "nginx:latest").unwrap();
        let ep_pos = argv.iter().position(|a| a == "--entrypoint").unwrap();
        assert!(ep_pos < img_pos, "entrypoint must precede image");
        assert_eq!(argv.last().unwrap(), "echo hello");
    }

    #[test]
    fn test_build_argv_minimal() {
        let spec = BuildSpec {
            service: "server".to_string(),
            context: PathBuf::from(".."),
            dockerfile: Some(PathBuf::from("containers/Containerfile.server")),
            args: BTreeMap::new(),
            target: None,
            tag: "burble_server:latest".to_string(),
            no_cache: false,
        };
        let argv = build_argv(&spec);
        assert_eq!(&argv[..2], &["podman", "build"]);
        assert!(argv.contains(&"--tag".to_string()));
        assert!(argv.contains(&"burble_server:latest".to_string()));
        assert!(argv.contains(&"--file".to_string()));
        assert!(!argv.contains(&"--no-cache".to_string()));
        assert_eq!(argv.last().unwrap(), "..");
    }

    #[test]
    fn test_build_argv_with_build_args_and_no_cache() {
        let mut args = BTreeMap::new();
        args.insert("FEATURES".to_string(), "persistent".to_string());
        let spec = BuildSpec {
            service: "verisimdb".to_string(),
            context: PathBuf::from("../tools/nextgen-databases/verisimdb"),
            dockerfile: Some(PathBuf::from("container/Containerfile")),
            args,
            target: None,
            tag: "burble_verisimdb:latest".to_string(),
            no_cache: true,
        };
        let argv = build_argv(&spec);
        assert!(argv.contains(&"--no-cache".to_string()));
        assert!(argv.contains(&"--build-arg".to_string()));
        assert!(argv.contains(&"FEATURES=persistent".to_string()));
    }

    #[test]
    fn test_network_create_argv() {
        let mut labels = BTreeMap::new();
        labels.insert("io.podman.compose.project".to_string(), "burble".to_string());
        let spec = NetworkSpec {
            name: "burble-internal".to_string(),
            driver: Some("bridge".to_string()),
            labels,
        };
        let argv = network_create_argv(&spec);
        assert_eq!(&argv[..3], &["podman", "network", "create"]);
        assert!(argv.contains(&"--driver".to_string()));
        assert!(argv.contains(&"bridge".to_string()));
        assert!(argv.contains(&"--label".to_string()));
        assert_eq!(argv.last().unwrap(), "burble-internal");
    }

    #[test]
    fn test_volume_create_argv() {
        let mut labels = BTreeMap::new();
        labels.insert("io.podman.compose.project".to_string(), "burble".to_string());
        let spec = VolumeSpec {
            name: "burble-verisimdb-data".to_string(),
            driver: Some("local".to_string()),
            labels,
        };
        let argv = volume_create_argv(&spec);
        assert_eq!(&argv[..3], &["podman", "volume", "create"]);
        assert!(argv.contains(&"--driver".to_string()));
        assert!(argv.contains(&"local".to_string()));
        assert_eq!(argv.last().unwrap(), "burble-verisimdb-data");
    }
}
