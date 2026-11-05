<!-- SPDX-License-Identifier: MPL-2.0 -->

# burble-client

Embeddable Rust client for Burble's non-voice `game:<session_id>` channel.
`GameClient::join` speaks the `legacy-json-v1` lane over Phoenix V2 JSON.
That lane is for local development/test play. It has no exclusive-seat ticket,
0.8 binary negotiation, durable journal or applied-state receipt. A `Relayed`
result records relay acceptance, not peer delivery.

```rust,no_run
use burble_client::{Auth, GameClient, JoinConfig};

# async fn connect() -> Result<(), burble_client::Error> {
let client = GameClient::join(JoinConfig {
    endpoint: "ws://127.0.0.1:6473/voice/websocket".into(),
    session_id: "shared-session-code".into(),
    game_id: "idaptik".into(),
    role: "hacker".into(),
    auth: Auth::Guest { display_name: "Ada".into() },
}).await?;
# drop(client); Ok(()) }
```

Existing query parameters are preserved; authentication and `vsn=2.0.0` are
appended safely. `Auth::Token` authenticates a socket; it does not grant a
session seat. Production's scoped `admission-v1` join additionally needs the
correct session/epoch/role/participant ticket. The current high-level
`GameClient` is not a scoped or 0.8 consumer.

Run unit tests with `cargo test --manifest-path client/rust/Cargo.toml`. For a
local legacy two-seat relay check, start the loopback development server and run:

```console
BURBLE_TEST_URL=ws://127.0.0.1:6473/voice/websocket \
  cargo run --manifest-path client/rust/Cargo.toml --example idaptik_roundtrip
```

For the scoped admission contract, install the locked server dependencies and
run the explicit CI gate on Unix:

```console
cargo run --locked --manifest-path client/rust/Cargo.toml --example admission_conformance
```

This gate owns a real loopback Bandit/Phoenix process and connects independent
WebSocket clients through the lower-level transport API. It exercises a
double-seat race, unsigned guest/identity/version refusals, typed exchange,
an unread command ACK followed by rejoin and deduplication, connection fencing,
the actual 16-KiB frame refusal, stale epoch and authority restart refusal.
Missing Mix or dependencies fail the command. Credentials stay in a private
temporary fixture and are removed when the process exits.

The gate does not establish remotely exposed hosting, TLS deployment or 0.8
durable/binary conformance. See
[ADR 0018](../../docs/decisions/0018-session-admission-boundary.adoc)
for the exact contract and remaining delivery gates.
