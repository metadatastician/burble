// SPDX-License-Identifier: MPL-2.0

use crate::{Broadcast, Error, PhoenixClient, WebSocketTransport};
use serde_json::{Value, json};
use std::time::Duration;
use url::Url;

/// Socket authentication accepted by Burble.
#[derive(Debug, Clone)]
pub enum Auth {
    Guest { display_name: String },
    Token(String),
}

/// Everything needed to connect and join a Burble game session.
#[derive(Debug, Clone)]
pub struct JoinConfig {
    /// Full socket endpoint, normally `ws://host:port/voice/websocket`.
    pub endpoint: String,
    pub session_id: String,
    pub game_id: String,
    pub role: String,
    pub auth: Auth,
}

/// Whether the legacy relay accepted a command for broadcast.
///
/// `Relayed` is not evidence of durable commit, peer receipt or application.
/// This client speaks `legacy-json-v1`; it does not negotiate the 0.8 fabric.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RelayOutcome {
    Relayed,
    Dropped { reason: String },
}

/// Typed view of a game-session broadcast.
#[derive(Debug, Clone, PartialEq)]
pub enum GameBroadcast {
    PeerJoined { role: String },
    PeerLeft { role: String },
    Command(Value),
    Event(Value),
    Other(Broadcast),
}

/// High-level, embeddable client for one Burble game-session seat.
pub struct GameClient {
    phoenix: PhoenixClient<WebSocketTransport>,
}

impl GameClient {
    /// Connect, authenticate, and join in one operation.
    pub async fn join(config: JoinConfig) -> Result<Self, Error> {
        let mut endpoint = Url::parse(&config.endpoint)?;
        {
            let mut query = endpoint.query_pairs_mut();
            query.append_pair("vsn", "2.0.0");
            match &config.auth {
                Auth::Guest { display_name } => {
                    query.append_pair("guest", "true");
                    query.append_pair("display_name", display_name);
                }
                Auth::Token(token) => {
                    query.append_pair("token", token);
                }
            }
        }
        let transport = WebSocketTransport::connect(endpoint.as_str()).await?;
        let mut phoenix = PhoenixClient::new(transport);
        phoenix
            .join(
                &format!("game:{}", config.session_id),
                json!({"game": config.game_id, "role": config.role}),
            )
            .await?;
        Ok(Self { phoenix })
    }

    pub async fn send_command(&mut self, command: Value) -> Result<RelayOutcome, Error> {
        require_string_tag(&command, "cmd", "command")?;
        let response = self.phoenix.push("command", command).await?;
        if response.get("relayed").and_then(Value::as_bool) == Some(true) {
            Ok(RelayOutcome::Relayed)
        } else {
            Ok(RelayOutcome::Dropped {
                reason: response
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("server did not provide a reason")
                    .to_owned(),
            })
        }
    }

    pub async fn send_event(&mut self, event: Value) -> Result<RelayOutcome, Error> {
        require_string_tag(&event, "event", "event")?;
        let response = self.phoenix.push("event", event).await?;
        if response.get("relayed").and_then(Value::as_bool) == Some(true) {
            Ok(RelayOutcome::Relayed)
        } else {
            Ok(RelayOutcome::Dropped {
                reason: response
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("server did not provide a reason")
                    .to_owned(),
            })
        }
    }

    pub async fn ping(&mut self) -> Result<(), Error> {
        let response = self.phoenix.push("ping", json!({})).await?;
        if response.get("pong").and_then(Value::as_bool) == Some(true) {
            Ok(())
        } else {
            Err(Error::Protocol(format!(
                "invalid ping response: {response}"
            )))
        }
    }

    pub async fn next_event(&mut self, wait: Duration) -> Result<Option<GameBroadcast>, Error> {
        Ok(self
            .phoenix
            .next_broadcast(wait)
            .await?
            .map(classify_broadcast))
    }

    pub async fn leave(&mut self) {
        self.phoenix.leave().await;
    }
}

fn require_string_tag(value: &Value, tag: &str, kind: &str) -> Result<(), Error> {
    if value.get(tag).and_then(Value::as_str).is_some() {
        Ok(())
    } else {
        Err(Error::Protocol(format!(
            "{kind} must be an object carrying a string \"{tag}\" tag"
        )))
    }
}

fn classify_broadcast(message: Broadcast) -> GameBroadcast {
    match message.event.as_str() {
        "peer_joined" => message
            .payload
            .get("role")
            .and_then(Value::as_str)
            .map(|role| GameBroadcast::PeerJoined {
                role: role.to_owned(),
            })
            .unwrap_or(GameBroadcast::Other(message)),
        "peer_left" => message
            .payload
            .get("role")
            .and_then(Value::as_str)
            .map(|role| GameBroadcast::PeerLeft {
                role: role.to_owned(),
            })
            .unwrap_or(GameBroadcast::Other(message)),
        "command" => GameBroadcast::Command(message.payload),
        "event" => GameBroadcast::Event(message.payload),
        _ => GameBroadcast::Other(message),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_known_and_preserves_unknown_broadcasts() {
        assert_eq!(
            classify_broadcast(Broadcast {
                event: "peer_joined".into(),
                payload: json!({"role": "hacker"})
            }),
            GameBroadcast::PeerJoined {
                role: "hacker".into()
            }
        );
        assert!(matches!(
            classify_broadcast(Broadcast {
                event: "future".into(),
                payload: json!({"x": 1})
            }),
            GameBroadcast::Other(_)
        ));
    }

    #[test]
    fn rejects_untagged_payload_before_network_send() {
        assert!(require_string_tag(&json!({}), "cmd", "command").is_err());
        assert!(require_string_tag(&json!({"cmd": 1}), "cmd", "command").is_err());
        assert!(require_string_tag(&json!({"cmd": "Jump"}), "cmd", "command").is_ok());
    }
}
