# Buzz push listener — end-to-end evidence

Intent: an owner mention in the private Buzz channel should reach firstmate in
seconds through a long-running relay listener, instead of waiting up to 300s for
the watcher's check sweep; the sweep stays as the backstop, and the listener is a
built-in process-event source (option 1).

| File | What it shows |
|---|---|
| `buzz-push-listener-walkthrough.txt` | The operator transcript: `fm-buzz.sh enable` → `listener: connected` → `fm-procevent.sh list` shows the built-in `buzz` source → owner posts a mention → the live watcher wakes with `buzz-mention <rid>` in **2s** with its own sweep 300s away → persisted `state/x-inbox/<rid>.json` → reply signed into the original thread → `disable` → `listener: stopped`, no sources registered, relay session closed. Hermetic: invented keys, signed fixture events, a fake `buzz` CLI, a stub relay client emitting the helper's three stdout signals. No relay contacted. |
| `off-switch-default-cadence.txt` | The marker alone is the off switch, at the shipped 60s cadence (no `FM_BUZZ_LISTEN_RECHECK_SECONDS` override): with zero channel traffic, removing `config/buzz-bridge.enabled` stops the adapter **and** the relay client 60s later and clears the connection marker, leaving the source registered for a later enable. |
| `real-helper-binary-wired-in.txt` | The real `fm-buzz-listen` binary (built below) wired into the real `bin/fm-procevent-buzz.sh` adapter against an unreachable relay: usage goes to stderr only, `enable` succeeds, status reads `listener: disconnected` (documented as a reconnect window, not a fault), the source stays `live`, and removing the marker stops the real relay client. |
| `helper-rebuild-and-test.log` | Independent rebuild of `bin/fm-buzz-listen.rs` from a clean clone of `relay-v0.3.0` (pin `75d38b6c`), using the two commands in `docs/configuration.md` verbatim: both run with no `Cargo.toml`/`Cargo.lock` edit (`git status` shows only the untracked `crates/buzz-cli/src/bin/`), and all 3 helper tests pass — `a_silent_relay_does_not_end_a_live_session`, `auth_and_subscription_emit_only_a_matching_live_doorbell`, `a_dropped_session_reconnects_and_keeps_delivering`. Source hash matches the committed file. |

Not covered end to end: the real binary completing a NIP-42 handshake and
delivering a `match` over a live socket. Its CLI entrypoint only accepts
`https://` and converts to `wss://`, and `rustls-platform-verifier` trusts the
system keychain, so a local plaintext or self-signed relay stub cannot be used
without changing system trust. That seam is covered instead by the helper's own
Rust tests (real local WebSocket relay, signature-verified AUTH event, exact REQ
filter, matching vs non-matching events, reconnect) plus the shell suite driving
the adapter on the identical three stdout signals.

Earlier files in this directory (`buzz-listener-demo.*`, `push-listener-demo.*`,
`helper-build-test.log`, `fm-buzz-listen-cargo-test.log`,
`real-helper-integration.*`) are from earlier rounds of the same run and cover
the same ground; `real-helper-integration.txt` additionally confirms the bridge
secret appears in neither the helper's argv nor `fm-buzz.sh status`.
