//! Build as a second binary of the pinned Buzz CLI package.
//! stdout is a fixed protocol for fm-procevent-buzz.sh. Relay data and errors
//! never cross it. The key file is opened only after receiving a challenge.

use std::fs::File;
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use buzz_ws_client::{NostrWsConnection, RelayMessage, build_auth_event};
use nostr::{Keys, PublicKey};
use serde_json::json;
use tokio::time::{sleep, timeout};

const SUBSCRIPTION: &str = "firstmate-buzz";
const HANDSHAKE: Duration = Duration::from_secs(20);
// The relay's own WebSocket Ping keeps a healthy session readable, so this
// bound is only the last resort for a socket that died without a close.
const IDLE_READ: Duration = Duration::from_secs(1800);

struct Config {
    relay: String,
    channel: String,
    owner: PublicKey,
    bridge: PublicKey,
    key_file: PathBuf,
}

type SessionResult<T> = Result<T, ()>;

fn signal(line: &str) -> io::Result<()> {
    let mut out = io::stdout().lock();
    writeln!(out, "{line}")?;
    out.flush()
}

fn load_keys(path: &Path) -> SessionResult<Keys> {
    let file = File::open(path).map_err(|_| ())?;
    for line in BufReader::new(file).lines() {
        let line = line.map_err(|_| ())?;
        if let Some(secret) = line.trim_start().strip_prefix("Secret key:") {
            let hex: String = secret
                .chars()
                .filter(|c| !c.is_ascii_whitespace())
                .collect();
            if hex.len() != 64
                || !hex
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            {
                return Err(());
            }
            return Keys::parse(&hex).map_err(|_| ());
        }
    }
    Err(())
}

async fn authenticate(conn: &mut NostrWsConnection, config: &Config) -> SessionResult<()> {
    let challenge = timeout(HANDSHAKE, async {
        loop {
            if let RelayMessage::Auth { challenge } =
                conn.next_event(HANDSHAKE).await.map_err(|_| ())?
            {
                return Ok::<_, ()>(challenge);
            }
        }
    })
    .await
    .map_err(|_| ())??;

    let event = {
        let keys = load_keys(&config.key_file)?;
        if keys.public_key() != config.bridge {
            return Err(());
        }
        build_auth_event(&challenge, &config.relay, &keys, None)
            .await
            .map_err(|_| ())?
    };
    let event_id = event.id.to_hex();
    timeout(HANDSHAKE, async {
        conn.send_raw(&json!(["AUTH", event]))
            .await
            .map_err(|_| ())?;
        loop {
            if let RelayMessage::Ok(ok) = conn.next_event(HANDSHAKE).await.map_err(|_| ())? {
                if ok.event_id == event_id {
                    return ok.accepted.then_some(()).ok_or(());
                }
            }
        }
    })
    .await
    .map_err(|_| ())?
}

async fn listen(
    config: &Config,
    mut report: impl FnMut(&str) -> io::Result<()>,
) -> SessionResult<()> {
    let mut conn = timeout(HANDSHAKE, NostrWsConnection::connect(&config.relay))
        .await
        .map_err(|_| ())?
        .map_err(|_| ())?;
    authenticate(&mut conn, config).await?;

    timeout(HANDSHAKE, async {
        conn.send_raw(&json!(["REQ", SUBSCRIPTION, {
            "kinds": [9], "authors": [config.owner.to_hex()],
            "#h": [config.channel], "#p": [config.bridge.to_hex()], "limit": 0,
        }]))
        .await
        .map_err(|_| ())?;
        loop {
            match conn.next_event(HANDSHAKE).await.map_err(|_| ())? {
                RelayMessage::Eose { subscription_id } if subscription_id == SUBSCRIPTION => {
                    return Ok(());
                }
                RelayMessage::Closed {
                    subscription_id, ..
                } if subscription_id == SUBSCRIPTION => return Err(()),
                _ => {}
            }
        }
    })
    .await
    .map_err(|_| ())??;

    report("connected").map_err(|_| ())?;
    let bridge = config.bridge.to_hex();
    loop {
        match conn.next_event(IDLE_READ).await.map_err(|_| ())? {
            RelayMessage::Event {
                subscription_id,
                event,
            } if subscription_id == SUBSCRIPTION
                && event.kind.as_u16() == 9
                && event.pubkey == config.owner =>
            {
                let mut channel_tags = event
                    .tags
                    .iter()
                    .filter(|tag| tag.as_slice().first().is_some_and(|key| key == "h"));
                let channel_matches = channel_tags.next().and_then(|tag| tag.as_slice().get(1))
                    == Some(&config.channel)
                    && channel_tags.next().is_none();
                let mentioned = event.tags.iter().any(|tag| {
                    let fields = tag.as_slice();
                    fields.first().is_some_and(|key| key == "p") && fields.get(1) == Some(&bridge)
                });
                if channel_matches && mentioned {
                    report("match").map_err(|_| ())?;
                }
            }
            RelayMessage::Closed {
                subscription_id, ..
            } if subscription_id == SUBSCRIPTION => return Err(()),
            RelayMessage::Auth { .. } => return Err(()),
            _ => {}
        }
    }
}

fn config() -> Option<Config> {
    let mut args = std::env::args_os().skip(1);
    let relay = args.next()?.into_string().ok()?;
    let channel = args.next()?.into_string().ok()?;
    let owner = PublicKey::from_hex(args.next()?.to_str()?).ok()?;
    let bridge = PublicKey::from_hex(args.next()?.to_str()?).ok()?;
    let key_file = args.next()?.into();
    if args.next().is_some() {
        return None;
    }
    let relay = format!("wss://{}", relay.strip_prefix("https://")?);
    Some(Config {
        relay,
        channel,
        owner,
        bridge,
        key_file,
    })
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let Some(config) = config() else {
        eprintln!(
            "usage: fm-buzz-listen <https-relay> <channel> <owner-pubkey> <bridge-pubkey> <key-file>"
        );
        std::process::exit(2);
    };
    if rustls::crypto::ring::default_provider()
        .install_default()
        .is_err()
    {
        std::process::exit(1);
    }
    let mut delay = 1;
    loop {
        let started = Instant::now();
        let _ = listen(&config, signal).await;
        if signal("disconnected").is_err() {
            return;
        }
        if started.elapsed() >= Duration::from_secs(60) {
            delay = 1;
        }
        sleep(Duration::from_secs(delay)).await;
        delay = (delay * 2).min(30);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::{SinkExt, StreamExt};
    use nostr::{Event, EventBuilder, Kind, Tag};
    use serde_json::Value;
    use tokio::net::TcpListener;
    use tokio_tungstenite::{accept_async, tungstenite::Message};

    #[tokio::test]
    async fn auth_and_subscription_emit_only_a_matching_live_doorbell() {
        let relay = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", relay.local_addr().unwrap());
        let key_dir = tempfile::tempdir().unwrap();
        let key_path = key_dir.path().join("bridge.key");
        let bridge_key = "2".repeat(64);
        let bridge = Keys::parse(&bridge_key).unwrap().public_key();
        let owner = Keys::generate();
        let channel = "8acb1df7-1f23-45a7-88f7-1234567890ab";
        let config = Config {
            relay: url.clone(),
            channel: channel.into(),
            owner: owner.public_key(),
            bridge,
            key_file: key_path.clone(),
        };
        let server = tokio::spawn(async move {
            let (tcp, _) = relay.accept().await.unwrap();
            let mut ws = accept_async(tcp).await.unwrap();
            // The file is created after the socket upgrade.
            std::fs::write(key_path, format!("Secret key: {bridge_key}\n")).unwrap();
            ws.send(Message::Text(json!(["AUTH", "fixture"]).to_string().into()))
                .await
                .unwrap();
            let raw = ws.next().await.unwrap().unwrap().into_text().unwrap();
            let auth: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(auth[0], "AUTH");
            let event: Event = serde_json::from_value(auth[1].clone()).unwrap();
            event.verify().unwrap();
            assert_eq!(event.pubkey, bridge);
            assert_eq!(event.kind.as_u16(), 22242);
            assert!(
                event
                    .tags
                    .iter()
                    .any(|tag| tag.as_slice() == ["challenge", "fixture"])
            );
            assert!(
                event
                    .tags
                    .iter()
                    .any(|tag| tag.as_slice() == ["relay", &url])
            );
            ws.send(Message::Text(
                json!(["OK", event.id, true, ""]).to_string().into(),
            ))
            .await
            .unwrap();

            let raw = ws.next().await.unwrap().unwrap().into_text().unwrap();
            let req: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(
                req,
                json!(["REQ", SUBSCRIPTION, {
                    "kinds": [9], "authors": [owner.public_key().to_hex()], "#h": [channel],
                    "#p": [bridge.to_hex()], "limit": 0,
                }])
            );
            let matching = EventBuilder::new(Kind::Custom(9), "fixture mention")
                .tags([Tag::parse(["h", channel]).unwrap(), Tag::public_key(bridge)])
                .sign(&owner)
                .await
                .unwrap();
            let wrong_channel = EventBuilder::new(Kind::Custom(9), "other channel")
                .tags([Tag::parse(["h", "other"]).unwrap(), Tag::public_key(bridge)])
                .sign(&owner)
                .await
                .unwrap();
            for row in [
                json!(["EVENT", SUBSCRIPTION, matching]),
                json!(["EOSE", SUBSCRIPTION]),
                json!(["EVENT", SUBSCRIPTION, wrong_channel]),
                json!(["EVENT", "unrelated", matching]),
                json!(["EVENT", SUBSCRIPTION, matching]),
                json!(["CLOSED", SUBSCRIPTION, "fixture completed"]),
            ] {
                ws.send(Message::Text(row.to_string().into()))
                    .await
                    .unwrap();
            }
        });
        let mut signals = Vec::new();
        let closed = timeout(
            Duration::from_secs(10),
            listen(&config, |line| {
                signals.push(line.to_owned());
                Ok(())
            }),
        )
        .await
        .unwrap();
        server.await.unwrap();
        assert!(closed.is_err());
        assert_eq!(signals, ["connected", "match"]);
    }

    /// A private channel is quiet by design, so a session that reads nothing
    /// for far longer than the relay's keepalive window must still be live.
    /// The wait is virtual: the clock is paused once the subscription is live.
    #[tokio::test]
    async fn a_silent_relay_does_not_end_a_live_session() {
        assert!(
            IDLE_READ >= Duration::from_secs(1800),
            "a quiet owner channel needs at least a 30-minute read bound"
        );
        let silence = IDLE_READ.saturating_sub(Duration::from_secs(60));
        let relay = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", relay.local_addr().unwrap());
        let key_dir = tempfile::tempdir().unwrap();
        let key_path = key_dir.path().join("bridge.key");
        let bridge_key = "3".repeat(64);
        let bridge = Keys::parse(&bridge_key).unwrap().public_key();
        let owner = Keys::generate();
        let channel = "8acb1df7-1f23-45a7-88f7-1234567890ab";
        let config = Config {
            relay: url.clone(),
            channel: channel.into(),
            owner: owner.public_key(),
            bridge,
            key_file: key_path.clone(),
        };
        std::fs::write(&key_path, format!("Secret key: {bridge_key}\n")).unwrap();
        let server = tokio::spawn(async move {
            let (tcp, _) = relay.accept().await.unwrap();
            let mut ws = accept_async(tcp).await.unwrap();
            ws.send(Message::Text(json!(["AUTH", "fixture"]).to_string().into()))
                .await
                .unwrap();
            let raw = ws.next().await.unwrap().unwrap().into_text().unwrap();
            let auth: Value = serde_json::from_str(&raw).unwrap();
            let event: Event = serde_json::from_value(auth[1].clone()).unwrap();
            ws.send(Message::Text(
                json!(["OK", event.id, true, ""]).to_string().into(),
            ))
            .await
            .unwrap();
            ws.next().await.unwrap().unwrap();
            ws.send(Message::Text(
                json!(["EOSE", SUBSCRIPTION]).to_string().into(),
            ))
            .await
            .unwrap();
            sleep(silence).await;
            let mention = EventBuilder::new(Kind::Custom(9), "after the silence")
                .tags([Tag::parse(["h", channel]).unwrap(), Tag::public_key(bridge)])
                .sign(&owner)
                .await
                .unwrap();
            for row in [
                json!(["EVENT", SUBSCRIPTION, mention]),
                json!(["CLOSED", SUBSCRIPTION, "fixture completed"]),
            ] {
                ws.send(Message::Text(row.to_string().into())).await.unwrap();
            }
        });
        let mut signals = Vec::new();
        let closed = timeout(
            silence * 6,
            listen(&config, |line| {
                if line == "connected" {
                    tokio::time::pause();
                }
                signals.push(line.to_owned());
                Ok(())
            }),
        )
        .await
        .unwrap();
        server.await.unwrap();
        assert!(closed.is_err());
        assert_eq!(signals, ["connected", "match"]);
    }
}
