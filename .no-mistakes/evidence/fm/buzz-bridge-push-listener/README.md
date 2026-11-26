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

Added at the final commit `ce44c20f` (re-verified transcripts, plus the two
fixes this round decided):

| File | What it shows |
|---|---|
| `buzz-listener-pickup-transcript.txt` | The same operator path re-run at `ce44c20f`: `enable` → `listener: connected` → `fm-procevent.sh list` shows the built-in `buzz` source → owner posts a mention → a live watcher whose own sweep is pinned out of reach wakes with `buzz-mention <rid>` in **2.2s** → the persisted `state/x-inbox/<rid>.json` → the relay reads the push caused (one `messages get` plus the eyes reaction, no sweep) → the durable `buzz-push` wake row → `disable` → `listener: stopped` and the relay helper gone. |
| `buzz-off-switch-and-status-transcript.txt` | The marker-only off switch at the shipped 60s cadence with no override and zero channel traffic: adapter and relay client both exit **59.8s** after `config/buzz-bridge.enabled` is removed by hand, the connection marker is cleared, and the source stays registered. Then the three status labels side by side: `listener: unusable (BUZZ_LISTENER is not an executable file)` for a path that moved versus `listener: not configured` for a poll-only home. |
| `buzz-poll-lock-diagnostic.txt` | A single-flight poll lock nothing can reclaim: the sweep prints `buzz-bridge-error cannot reclaim <path>; the Buzz poll cannot run`, exits 0 so the watcher's check does not fail, records the line in `state/buzz/poll.error` for `fm-buzz.sh status`, stays quiet on the next sweep (bounded, not once per 300s), and resumes intake once the lock is cleared. |

`bin/fm-buzz-listen.rs` is byte-identical at `ce44c20f` to the source the
`helper-rebuild-and-test.log` / `fm-buzz-listen-cargo-test.log` runs built
(sha256 `4a1a22a7f53c1bc5bc764f1dc90012b0bc75aae4065c1e9d16d60031e2bc0987`), so
that build and its 3 passing helper tests still describe the shipped helper.

The three transcripts above were produced by driving the real `bin/fm-buzz.sh`,
`bin/fm-procevent*.sh`, `bin/fm-buzz-poll.sh` and `bin/fm-watch.sh` against the
hermetic fixtures from `tests/fm-buzz-bridge.test.sh` (its home builder, signed
fixture events and fake `buzz` CLI) from a scratch driver outside the worktree.

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
