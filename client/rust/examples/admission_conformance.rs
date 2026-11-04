// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//! Executable conformance gate against a real, loopback Bandit/Phoenix listener.
//! Run from any directory with `cargo run --locked --example admission_conformance`.
//! Mix and the locked server dependencies are required; missing tools fail the gate.

use burble_client::{TextTransport, WebSocketTransport};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    error::Error,
    fs,
    io::Write,
    path::PathBuf,
    process::{Child, Command, Stdio},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::time::{Instant, sleep, timeout};
use url::Url;

type Result<T> = std::result::Result<T, Box<dyn Error>>;

struct Host {
    child: Child,
    dir: PathBuf,
    generation: u64,
}

impl Host {
    fn start() -> Result<Self> {
        if !cfg!(unix) {
            return Err("this CI probe requires Unix private fixture permissions".into());
        }
        let dir = std::env::temp_dir().join(format!(
            "burble-admission-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()
        ));
        let mut builder = fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(&dir)?;
        let server = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../server");
        let child = match Command::new("mix")
            .args(["run", "test/support/admission_host.exs"])
            .current_dir(server)
            .env("MIX_ENV", "test")
            .env("BURBLE_ADMISSION_FIXTURE", dir.join("fixture.json"))
            .env_remove("PHX_SERVER")
            .env_remove("ANTHROPIC_API_KEY")
            .stdin(Stdio::piped())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .spawn()
        {
            Ok(child) => child,
            Err(error) => {
                fs::remove_dir_all(&dir)?;
                return Err(error.into());
            }
        };
        Ok(Self {
            child,
            dir,
            generation: 0,
        })
    }

    async fn fixture(&mut self) -> Result<Value> {
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            if let Some(status) = self.child.try_wait()? {
                return Err(format!("admission host exited before readiness: {status}").into());
            }
            if let Ok(bytes) = fs::read(self.dir.join("fixture.json")) {
                let fixture: Value = serde_json::from_slice(&bytes)?;
                if fixture["generation"].as_u64() == Some(self.generation) {
                    return Ok(fixture);
                }
            }
            if Instant::now() >= deadline {
                return Err("admission host did not become ready".into());
            }
            sleep(Duration::from_millis(50)).await;
        }
    }

    async fn control(&mut self, command: &str) -> Result<Value> {
        self.generation += 1;
        let input = self.child.stdin.as_mut().ok_or("host stdin unavailable")?;
        writeln!(input, "{command}")?;
        input.flush()?;
        self.fixture().await
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

struct Peer {
    transport: WebSocketTransport,
    topic: String,
    next_ref: u64,
    pending: VecDeque<Value>,
}

impl Peer {
    async fn connect(fixture: &Value, principal: Option<&str>) -> Result<Self> {
        let mut url = Url::parse(fixture["endpoint"].as_str().ok_or("missing endpoint")?)?;
        {
            let mut query = url.query_pairs_mut();
            query.append_pair("vsn", "2.0.0");
            if let Some(principal) = principal {
                query.append_pair(
                    "token",
                    fixture["tokens"][principal]
                        .as_str()
                        .ok_or("missing token")?,
                );
            } else {
                query.append_pair("guest", "true");
                query.append_pair("display_name", "alice");
            }
        }
        let transport = WebSocketTransport::connect(url.as_str()).await?;
        Ok(Self {
            transport,
            topic: format!(
                "game:{}",
                fixture["provision"]["session_id"]
                    .as_str()
                    .ok_or("missing session")?
            ),
            next_ref: 0,
            pending: VecDeque::new(),
        })
    }

    async fn send(&mut self, event: &str, payload: Value) -> Result<String> {
        self.next_ref += 1;
        let reference = self.next_ref.to_string();
        self.transport
            .send_text(serde_json::to_string(&json!([
                "1", reference, self.topic, event, payload
            ]))?)
            .await?;
        Ok(reference)
    }

    async fn frame(&mut self) -> Result<Value> {
        let text = timeout(Duration::from_secs(5), self.transport.recv_text())
            .await??
            .ok_or("WebSocket closed")?;
        let frame: Value = serde_json::from_str(&text)?;
        if frame.as_array().is_none_or(|parts| parts.len() != 5) {
            return Err("invalid Phoenix frame".into());
        }
        Ok(frame)
    }

    async fn request(&mut self, event: &str, payload: Value) -> Result<Value> {
        let reference = self.send(event, payload).await?;
        loop {
            let frame = self.frame().await?;
            if frame[1] == reference && frame[3] == "phx_reply" {
                return Ok(frame[4].clone());
            }
            if frame[3] == "phx_close" || frame[3] == "phx_error" {
                return Err("channel was fenced or closed".into());
            }
            self.pending.push_back(frame);
        }
    }

    async fn event(&mut self, event: &str) -> Result<Value> {
        loop {
            let frame = match self.pending.pop_front() {
                Some(frame) => frame,
                None => self.frame().await?,
            };
            if frame[3] == event {
                return Ok(frame[4].clone());
            }
        }
    }
}

fn join_params(fixture: &Value, role: &str) -> Value {
    json!({
        "protocol": "admission-v1", "game": "idaptik", "role": role,
        "epoch": fixture["provision"]["epoch"],
        "ticket": fixture["provision"]["grants"][role]["ticket"]
    })
}

fn accepted(reply: &Value) -> Result<&Value> {
    if reply["status"] != "ok" {
        // Never format the whole join response: it may contain a rejoin token.
        return Err("expected an accepted reply".into());
    }
    Ok(&reply["response"])
}

fn refused(reply: &Value, reason: &str) -> Result<()> {
    if reply["status"] != "error" || reply["response"]["reason"] != reason {
        return Err(format!("expected refusal: {reason}").into());
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let mut host = Host::start()?;
    let fixture = host.fixture().await?;

    let mut guest = Peer::connect(&fixture, None).await?;
    refused(
        &guest
            .request("phx_join", join_params(&fixture, "infiltrator"))
            .await?,
        "unauthenticated",
    )?;

    let mut mallory = Peer::connect(&fixture, Some("mallory")).await?;
    refused(
        &mallory
            .request("phx_join", join_params(&fixture, "infiltrator"))
            .await?,
        "scope_mismatch",
    )?;

    let mut wrong_version = Peer::connect(&fixture, Some("alice")).await?;
    let mut params = join_params(&fixture, "infiltrator");
    params["protocol"] = json!("0.8");
    refused(
        &wrong_version.request("phx_join", params).await?,
        "unsupported_protocol",
    )?;

    let mut left = Peer::connect(&fixture, Some("alice")).await?;
    let mut right = Peer::connect(&fixture, Some("alice")).await?;
    let (left_reply, right_reply) = tokio::join!(
        left.request("phx_join", join_params(&fixture, "infiltrator")),
        right.request("phx_join", join_params(&fixture, "infiltrator"))
    );
    let (left_reply, right_reply) = (left_reply?, right_reply?);
    let (mut alice, alice_receipt) = if left_reply["status"] == "ok" {
        refused(&right_reply, "ticket_consumed")?;
        (left, accepted(&left_reply)?.clone())
    } else {
        refused(&left_reply, "ticket_consumed")?;
        (right, accepted(&right_reply)?.clone())
    };
    let mut bob = Peer::connect(&fixture, Some("bob")).await?;
    accepted(
        &bob.request("phx_join", join_params(&fixture, "hacker"))
            .await?,
    )?;

    let command = json!({"cmd": "Jump", "seq": 1});
    let reply = alice.request("command", command).await?;
    let receipt = accepted(&reply)?;
    assert_eq!(receipt["evidence"], "accepted");
    for absent in ["durable", "delivered", "applied"] {
        assert!(
            receipt.get(absent).is_none(),
            "acceptance must not imply a stronger receipt"
        );
    }
    assert_eq!(bob.event("command").await?, json!({"cmd": "Jump"}));

    let event = json!({"event": "conformance-event", "value": 7});
    accepted(&bob.request("event", event.clone()).await?)?;
    assert_eq!(alice.event("event").await?, event);

    // Discard Alice's socket without reading the command ACK. Bob's received
    // frame establishes that the first attempt actually crossed the relay.
    alice
        .send("command", json!({"cmd": "Jump", "seq": 2}))
        .await?;
    assert_eq!(bob.event("command").await?, json!({"cmd": "Jump"}));
    drop(alice);
    let mut rejoined = Peer::connect(&fixture, Some("alice")).await?;
    let mut rejoin = join_params(&fixture, "infiltrator");
    rejoin
        .as_object_mut()
        .ok_or("invalid join params")?
        .remove("ticket");
    rejoin["rejoin_token"] = alice_receipt["rejoin_token"].clone();
    let reply = rejoined.request("phx_join", rejoin.clone()).await?;
    let rotated_token = accepted(&reply)?["rejoin_token"].clone();
    assert!(
        rotated_token != alice_receipt["rejoin_token"],
        "rejoin credential must rotate"
    );
    let retry = rejoined
        .request("command", json!({"cmd": "Jump", "seq": 2}))
        .await?;
    assert_eq!(accepted(&retry)?["relayed"], false);
    assert_eq!(accepted(&retry)?["reason"], "stale_or_duplicate");
    assert!(
        timeout(Duration::from_millis(200), bob.event("command"))
            .await
            .is_err(),
        "retry was duplicated to the peer"
    );

    // Check the actual WebSocket frame boundary, beyond the channel payload
    // bound: an oversized frame must close/refuse the connection.
    let mut oversized = Peer::connect(&fixture, Some("alice")).await?;
    let mut replacement = rejoin.clone();
    replacement["rejoin_token"] = rotated_token;
    accepted(&oversized.request("phx_join", replacement).await?)?;
    assert!(
        rejoined
            .request("command", json!({"cmd": "Jump", "seq": 3}))
            .await
            .is_err(),
        "a replaced connection must be fenced before another publish"
    );
    oversized
        .send(
            "event",
            json!({"event": "oversized", "body": "x".repeat(16_384)}),
        )
        .await?;
    match timeout(Duration::from_secs(5), oversized.frame()).await {
        Ok(Err(_)) => {}
        _ => return Err("16-KiB transport limit did not refuse the oversized frame".into()),
    }

    let next = host.control("rotate").await?;
    let mut stale = Peer::connect(&next, Some("bob")).await?;
    refused(
        &stale
            .request("phx_join", join_params(&fixture, "hacker"))
            .await?,
        "stale_epoch",
    )?;
    let mut live = Peer::connect(&next, Some("bob")).await?;
    accepted(
        &live
            .request("phx_join", join_params(&next, "hacker"))
            .await?,
    )?;

    host.control("restart").await?;
    let mut after_restart = Peer::connect(&next, Some("alice")).await?;
    refused(
        &after_restart
            .request("phx_join", join_params(&next, "infiltrator"))
            .await?,
        "unknown_session",
    )?;

    println!(
        "PASS: real WebSocket admission-v1 two-client exchange, guest/principal/version refusals, double-seat race, lost command ACK + rejoin dedup, 16-KiB refusal, old epoch and restart refusal; no durable/applied claim"
    );
    Ok(())
}
