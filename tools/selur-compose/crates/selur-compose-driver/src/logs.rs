//! Multi-service log multiplexer.
//!
//! [`tail_logs`] spawns one async reader per service and merges their output
//! through an `mpsc` channel into a stream of [`LogLine`]s prefixed with
//! `[<service>] `.
//!
//! # Design
//!
//! Each service gets its own `tokio::spawn` that reads lines from the
//! `LogStream` returned by [`Driver::logs`] and sends them to a shared
//! `mpsc::Sender<LogLine>`.  The caller receives a `Receiver` and can drain
//! it or forward it to stdout.

use std::collections::HashMap;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::mpsc;

use crate::{ContainerId, Driver};

// ---------------------------------------------------------------------------
// LogLine
// ---------------------------------------------------------------------------

/// A single prefixed log line from one service.
#[derive(Debug, Clone)]
pub struct LogLine {
    /// The compose service name.
    pub service: String,
    /// The raw line text (including any timestamp prepended by podman).
    pub line: String,
}

impl std::fmt::Display for LogLine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.service, self.line)
    }
}

// ---------------------------------------------------------------------------
// tail_logs
// ---------------------------------------------------------------------------

/// Multiplex log streams from multiple services into a single `mpsc` receiver.
///
/// `services` maps a service name to its container id.  For each entry,
/// a background task is spawned that reads lines from `driver.logs` and sends
/// them on the channel.  When all tasks finish (container exits or
/// `follow = false`), the channel closes and `recv()` returns `None`.
///
/// # Returns
///
/// An `mpsc::Receiver<LogLine>` that yields lines in arrival order.  Because
/// tasks run concurrently, lines from different services may interleave.
pub async fn tail_logs(
    driver: &dyn Driver,
    services: &HashMap<String, ContainerId>,
    follow: bool,
) -> mpsc::Receiver<LogLine> {
    // Channel capacity: buffer 1024 lines per service before applying backpressure.
    let (tx, rx) = mpsc::channel::<LogLine>(1024 * services.len().max(1));

    for (service_name, container_id) in services {
        let tx = tx.clone();
        let service = service_name.clone();

        // Obtain the log stream.
        let log_stream = match driver.logs(container_id, follow).await {
            Ok(stream) => stream,
            Err(e) => {
                // Send a synthetic error line rather than silently dropping the service.
                let _ = tx
                    .send(LogLine {
                        service: service.clone(),
                        line: format!("[driver error: {e}]"),
                    })
                    .await;
                continue;
            }
        };

        // Spawn a task that reads lines and forwards them.
        tokio::spawn(async move {
            let mut reader = BufReader::new(log_stream).lines();
            loop {
                match reader.next_line().await {
                    Ok(Some(line)) => {
                        if tx.send(LogLine { service: service.clone(), line }).await.is_err() {
                            // Receiver dropped — stop reading.
                            break;
                        }
                    }
                    Ok(None) => break, // EOF
                    Err(_) => break,   // I/O error
                }
            }
        });
    }

    // Drop our own sender clone so the channel closes when all tasks finish.
    drop(tx);
    rx
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::MockDriver;
    #[tokio::test]
    async fn test_tail_logs_empty_services() {
        let driver = MockDriver::new();
        let services = HashMap::new();
        let mut rx = tail_logs(&driver, &services, false).await;
        // Channel should close immediately.
        assert!(rx.recv().await.is_none());
    }

    #[tokio::test]
    async fn test_log_line_display() {
        let line = LogLine {
            service: "web".to_string(),
            line: "GET /health 200".to_string(),
        };
        assert_eq!(format!("{line}"), "[web] GET /health 200");
    }

    #[tokio::test]
    async fn test_tail_logs_single_service_mock() {
        // MockDriver returns an empty log stream, so we should get no lines but
        // the channel should close cleanly.
        let driver = MockDriver::new();
        let mut services = HashMap::new();
        services.insert("web".to_string(), ContainerId("c1".to_string()));

        let mut rx = tail_logs(&driver, &services, false).await;
        // With an empty stream the task exits immediately and the channel closes.
        // We might receive zero lines.
        let mut count = 0usize;
        while rx.recv().await.is_some() {
            count += 1;
        }
        // The mock returns tokio::io::empty(), so we expect 0 lines.
        assert_eq!(count, 0);
    }
}
