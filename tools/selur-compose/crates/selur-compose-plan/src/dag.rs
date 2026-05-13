//! DAG construction and topological wave generation.
//!
//! This module builds a directed graph over the services in a compose file and
//! uses Kahn's algorithm to produce topological waves (batches of services that
//! can be started concurrently because none has an inbound edge from any service
//! in the same batch).

use std::collections::{BTreeMap, HashMap, VecDeque};

use selur_compose_schema::{DependsCondition, DependsOn, Service};

use crate::PlanError;

// ---------------------------------------------------------------------------
// NodeId — a cheap, stable service name handle
// ---------------------------------------------------------------------------

/// A handle to a service node in the DAG.
///
/// Internally this is an index into the stable-sorted service name list so
/// that `petgraph::graphmap::DiGraphMap` can use it as a key without
/// requiring heap allocation per edge lookup.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct NodeId(usize);

impl NodeId {
    /// The integer index (position in sorted service name list).
    pub fn index(self) -> usize {
        self.0
    }

    /// Retrieve the service name from the sorted name list.
    pub fn name<'a>(&self, names: &'a [&str]) -> &'a str {
        names[self.0]
    }
}

// We need a way to go from NodeId back to a service name without the full name list
// in every call site.  We store a mapping alongside the graph.

/// The typed edge kind in the dependency graph.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum EdgeKind {
    /// Upstream service must have *started* before downstream.
    StartedBefore,
    /// Upstream service must be *healthy* before downstream starts.
    HealthyBefore,
    /// Upstream service must have *completed successfully* before downstream.
    CompletedBefore,
}

// ---------------------------------------------------------------------------
// ServiceGraph — wraps petgraph with our NodeId mapping
// ---------------------------------------------------------------------------

/// A directed graph of service dependencies.
#[derive(Debug)]
pub struct ServiceGraph {
    /// Stable-sorted list of service names; index == NodeId.
    pub names: Vec<String>,
    /// Adjacency list: `edges[from][to] = EdgeKind`.
    /// We use an explicit adjacency map rather than petgraph::graphmap so we
    /// avoid the orphaned-node problem with graphmap (isolated nodes never
    /// appear in iteration).
    pub edges: HashMap<NodeId, Vec<(NodeId, EdgeKind)>>,
    /// In-degree for every node (used by Kahn's algorithm).
    pub in_degree: HashMap<NodeId, usize>,
}

impl ServiceGraph {
    /// Iterate all nodes (including isolated ones).
    pub fn nodes(&self) -> impl Iterator<Item = NodeId> + '_ {
        (0..self.names.len()).map(NodeId)
    }

    /// Service name for a node id.
    pub fn name(&self, node: NodeId) -> &str {
        &self.names[node.0]
    }

    /// Outgoing edges from `node`.
    pub fn outgoing(&self, node: NodeId) -> &[(NodeId, EdgeKind)] {
        self.edges.get(&node).map(|v| v.as_slice()).unwrap_or(&[])
    }
}

// ---------------------------------------------------------------------------
// build_graph
// ---------------------------------------------------------------------------

/// Build a [`ServiceGraph`] from the active service map.
///
/// # Errors
///
/// Returns [`PlanError::MissingDependency`] when a `depends_on` entry names a
/// service not present in `active_services`.
pub fn build_graph<'a>(
    active_services: &BTreeMap<&'a str, &'a Service>,
) -> Result<ServiceGraph, PlanError> {
    // Stable-sorted name list: alphabetical (BTreeMap guarantees this).
    let names: Vec<String> = active_services.keys().map(|s| s.to_string()).collect();
    let name_to_id: HashMap<&str, NodeId> = names
        .iter()
        .enumerate()
        .map(|(i, n)| (n.as_str(), NodeId(i)))
        .collect();

    let mut edges: HashMap<NodeId, Vec<(NodeId, EdgeKind)>> = HashMap::new();
    let mut in_degree: HashMap<NodeId, usize> = (0..names.len()).map(|i| (NodeId(i), 0)).collect();

    for (svc_name, svc) in active_services {
        let from = name_to_id[svc_name];
        let deps = deps_of(svc);

        for (dep_name, kind) in deps {
            let to = name_to_id
                .get(dep_name.as_str())
                .copied()
                .ok_or_else(|| PlanError::MissingDependency {
                    from: svc_name.to_string(),
                    to: dep_name.clone(),
                })?;

            // Edge direction: `to` must run *before* `from`, i.e. `to → from`.
            edges.entry(to).or_default().push((from, kind));
            *in_degree.entry(from).or_insert(0) += 1;
        }
    }

    Ok(ServiceGraph {
        names,
        edges,
        in_degree,
    })
}

// ---------------------------------------------------------------------------
// topological_waves — Kahn's algorithm
// ---------------------------------------------------------------------------

/// Produce topological waves using Kahn's algorithm.
///
/// Each inner `Vec<NodeId>` is a set of services with no remaining inbound
/// edges — they can start concurrently once all services in prior waves are
/// running (or healthy, as required).
///
/// # Errors
///
/// Returns [`PlanError::Cycle`] when the graph contains a cycle.  The `path`
/// field lists the services that form the cycle (best-effort: it is the
/// remaining nodes after Kahn's terminates, sorted for determinism).
pub fn topological_waves(
    graph: &ServiceGraph,
    _active_services: &BTreeMap<&str, &Service>,
) -> Result<Vec<Vec<NodeId>>, PlanError> {
    let mut in_degree: HashMap<NodeId, usize> = graph.in_degree.clone();
    let mut remaining = graph.names.len();

    // Seed the queue with nodes that have zero in-degree.
    // Use a sorted seed so wave membership is deterministic across runs.
    let mut queue: VecDeque<NodeId> = {
        let mut seeds: Vec<NodeId> = in_degree
            .iter()
            .filter(|(_, &d)| d == 0)
            .map(|(&n, _)| n)
            .collect();
        seeds.sort_unstable();
        seeds.into()
    };

    let mut waves: Vec<Vec<NodeId>> = Vec::new();

    while !queue.is_empty() {
        // Drain the current queue into one wave.
        let wave: Vec<NodeId> = {
            let mut w: Vec<NodeId> = queue.drain(..).collect();
            w.sort_unstable(); // deterministic ordering within each wave
            w
        };
        remaining -= wave.len();

        // For each node in this wave, decrement the in-degree of successors.
        // Collect newly-zero-in-degree nodes for the next wave.
        let mut next_seeds: Vec<NodeId> = Vec::new();
        for &node in &wave {
            for &(succ, _kind) in graph.outgoing(node) {
                let deg = in_degree.entry(succ).or_insert(0);
                *deg -= 1;
                if *deg == 0 {
                    next_seeds.push(succ);
                }
            }
        }

        waves.push(wave);

        // Sort next seeds deterministically before enqueuing.
        next_seeds.sort_unstable();
        queue.extend(next_seeds);
    }

    // If any nodes remain, there is a cycle.
    if remaining > 0 {
        let cycle_nodes: Vec<String> = in_degree
            .iter()
            .filter(|(_, &d)| d > 0)
            .map(|(&n, _)| graph.name(n).to_string())
            .collect::<std::collections::BTreeSet<_>>() // sort
            .into_iter()
            .collect();
        return Err(PlanError::Cycle { path: cycle_nodes });
    }

    Ok(waves)
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/// Return the direct dependencies of `svc` as `(name, EdgeKind)` pairs.
fn deps_of(svc: &Service) -> Vec<(String, EdgeKind)> {
    match &svc.depends_on {
        DependsOn::Empty => vec![],
        DependsOn::List(names) => names
            .iter()
            .map(|n| (n.clone(), EdgeKind::StartedBefore))
            .collect(),
        DependsOn::Map(map) => map
            .iter()
            .map(|(name, spec)| {
                let kind = match spec.condition {
                    DependsCondition::ServiceStarted => EdgeKind::StartedBefore,
                    DependsCondition::ServiceHealthy => EdgeKind::HealthyBefore,
                    DependsCondition::ServiceCompletedSuccessfully => EdgeKind::CompletedBefore,
                };
                (name.clone(), kind)
            })
            .collect(),
    }
}

/// Return the names of services this service requires to be *healthy* before
/// it can start.  Used by the planner to insert `WaitHealthy` barriers.
pub fn healthy_dependencies(svc: &Service) -> Vec<String> {
    match &svc.depends_on {
        DependsOn::Map(map) => map
            .iter()
            .filter(|(_, spec)| spec.condition == DependsCondition::ServiceHealthy)
            .map(|(name, _)| name.clone())
            .collect(),
        _ => vec![],
    }
}

// ---------------------------------------------------------------------------
// NodeId::as_str_in helper (needs the names vec from the graph)
// ---------------------------------------------------------------------------

impl NodeId {
    /// Return the service name — requires the stable-sorted names list from
    /// [`ServiceGraph::names`].  Callers in `lib.rs` use [`ServiceGraph::name`]
    /// directly instead.
    ///
    /// Panics if `index >= names.len()`, which cannot happen for `NodeId`s
    /// produced by `build_graph` from the same graph.
    pub fn as_str_in<'a>(&self, names: &'a [String]) -> &'a str {
        names[self.0].as_str()
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use selur_compose_schema::{DependsCondition, DependsOn, DependsOnSpec, Service};

    fn stub_service() -> Service {
        // Build a minimal Service using the schema's structure.
        // We parse a minimal TOML snippet to get a valid Service.
        let toml = r#"
            [services.dummy]
            image = "scratch"
        "#;
        let compose = selur_compose_schema::parse_str(toml, None).unwrap();
        compose.services.into_values().next().unwrap()
    }

    fn service_with_depends(deps: DependsOn) -> Service {
        let mut svc = stub_service();
        svc.depends_on = deps;
        svc
    }

    #[test]
    fn test_single_node_wave() {
        let svc = stub_service();
        let services: BTreeMap<String, Service> = [("alpha".to_string(), svc)].into();
        let refs: BTreeMap<&str, &Service> = services.iter().map(|(k, v)| (k.as_str(), v)).collect();
        let graph = build_graph(&refs).unwrap();
        let waves = topological_waves(&graph, &refs).unwrap();
        assert_eq!(waves.len(), 1);
        assert_eq!(waves[0].len(), 1);
    }

    #[test]
    fn test_linear_chain_produces_two_waves() {
        // beta depends_on alpha → wave0=[alpha], wave1=[beta]
        let alpha = stub_service();
        let beta = service_with_depends(DependsOn::List(vec!["alpha".to_string()]));
        let services: BTreeMap<String, Service> = [
            ("alpha".to_string(), alpha),
            ("beta".to_string(), beta),
        ].into();
        let refs: BTreeMap<&str, &Service> = services.iter().map(|(k, v)| (k.as_str(), v)).collect();
        let graph = build_graph(&refs).unwrap();
        let waves = topological_waves(&graph, &refs).unwrap();
        assert_eq!(waves.len(), 2, "expected 2 waves, got {waves:?}");
        // wave0 has alpha (NodeId 0), wave1 has beta (NodeId 1)
        let w0_names: Vec<&str> = waves[0].iter().map(|n| graph.name(*n)).collect();
        let w1_names: Vec<&str> = waves[1].iter().map(|n| graph.name(*n)).collect();
        assert_eq!(w0_names, vec!["alpha"]);
        assert_eq!(w1_names, vec!["beta"]);
    }

    #[test]
    fn test_diamond_depends_on_healthy() {
        // Diamond: A → B, A → C, B → D (healthy), C → D (healthy)
        // Wave0=[A], Wave1=[B,C], Wave2=[D]
        // D should appear only once in the waves.
        let a = stub_service();
        let mut b = stub_service();
        b.depends_on = DependsOn::List(vec!["a".to_string()]);
        let mut c = stub_service();
        c.depends_on = DependsOn::List(vec!["a".to_string()]);
        let mut d = stub_service();
        d.depends_on = DependsOn::Map({
            let mut m = std::collections::BTreeMap::new();
            m.insert("b".to_string(), DependsOnSpec { condition: DependsCondition::ServiceHealthy, restart: false });
            m.insert("c".to_string(), DependsOnSpec { condition: DependsCondition::ServiceHealthy, restart: false });
            m
        });

        let services: BTreeMap<String, Service> = [
            ("a".to_string(), a),
            ("b".to_string(), b),
            ("c".to_string(), c),
            ("d".to_string(), d),
        ].into();
        let refs: BTreeMap<&str, &Service> = services.iter().map(|(k, v)| (k.as_str(), v)).collect();
        let graph = build_graph(&refs).unwrap();
        let waves = topological_waves(&graph, &refs).unwrap();

        // All four services should appear exactly once across all waves.
        let all_nodes: Vec<NodeId> = waves.iter().flatten().copied().collect();
        assert_eq!(all_nodes.len(), 4, "expected 4 nodes total, got {all_nodes:?}");

        // D must appear in a later wave than both B and C.
        let find_wave = |name: &str| -> usize {
            waves.iter().position(|w| w.iter().any(|n| graph.name(*n) == name)).unwrap()
        };
        assert!(find_wave("d") > find_wave("b"), "d must be after b");
        assert!(find_wave("d") > find_wave("c"), "d must be after c");
    }

    #[test]
    fn test_cycle_detected() {
        // A depends on B, B depends on A → cycle.
        let mut a = stub_service();
        a.depends_on = DependsOn::List(vec!["b".to_string()]);
        let mut b = stub_service();
        b.depends_on = DependsOn::List(vec!["a".to_string()]);

        let services: BTreeMap<String, Service> = [
            ("a".to_string(), a),
            ("b".to_string(), b),
        ].into();
        let refs: BTreeMap<&str, &Service> = services.iter().map(|(k, v)| (k.as_str(), v)).collect();
        let graph = build_graph(&refs).unwrap();
        let result = topological_waves(&graph, &refs);
        assert!(
            matches!(result, Err(PlanError::Cycle { .. })),
            "expected Cycle error, got {result:?}"
        );
    }

    #[test]
    fn test_missing_dependency_error() {
        let mut svc = stub_service();
        svc.depends_on = DependsOn::List(vec!["nonexistent".to_string()]);
        let services: BTreeMap<String, Service> = [("alpha".to_string(), svc)].into();
        let refs: BTreeMap<&str, &Service> = services.iter().map(|(k, v)| (k.as_str(), v)).collect();
        let result = build_graph(&refs);
        assert!(
            matches!(result, Err(PlanError::MissingDependency { .. })),
            "expected MissingDependency, got {result:?}"
        );
    }

    #[test]
    fn test_healthy_dependencies_extraction() {
        let mut svc = stub_service();
        svc.depends_on = DependsOn::Map({
            let mut m = std::collections::BTreeMap::new();
            m.insert("db".to_string(), DependsOnSpec {
                condition: DependsCondition::ServiceHealthy,
                restart: false,
            });
            m.insert("cache".to_string(), DependsOnSpec {
                condition: DependsCondition::ServiceStarted,
                restart: false,
            });
            m
        });
        let healthy = healthy_dependencies(&svc);
        assert_eq!(healthy, vec!["db"], "only db is healthy-conditioned");
    }
}
