#!/usr/bin/env python3
"""Filter and verify Buzz Stream events for the Buzz bridge (bin/fm-buzz-poll.sh).

Usage: fm-buzz-verify.py --owner <hex> --bridge <hex> --channel <uuid> --floor <epoch>

Reads a JSON array of Nostr events on stdin (the pinned Buzz CLI's
`messages get --format json` output) and prints a JSON array of the accepted
direct owner mentions, oldest first:
  {event_id, created_at, content, signer, parent, thread_root}

Signature verification is the one expensive stage and the relay is not trusted
to have checked it, so every distinct candidate the caller hands over is
verified. The input is what bounds the work: bin/fm-buzz-poll.sh makes one
newest-first read of at most its page limit, so an over-budget window arrives
capped at its newest events and the whole sweep stays inside the watcher's
per-check timeout. That read is scoped by channel and kind, not by author, so
the owner's latest mention is inside it unless more than that page limit of
channel messages are newer than the mention.

The paging overlap re-delivers the same event, so candidates are deduplicated
per distinct (id, sig) pair before the signature stage. The id alone would not
do: it fixes every signed field, so a copy of a real event carrying a junk
signature shares it, and collapsing the two would let that copy displace the
owner's own message.

An event is accepted only when ALL of these hold; anything else is dropped
silently, because the bridge's contract is "drop everything else":
  - kind 9 (Stream message); edits (40003), DMs, gift wraps and other kinds drop
  - exactly one `h` tag, equal to the configured channel
  - a `p` tag naming the bridge pubkey
  - signer (pubkey) equals the configured owner pubkey, and is not the bridge
  - created_at at or after the age floor
  - non-empty content; an `imeta` attachment is ignored, the text is the request
  - the event id recomputes per NIP-01 and the BIP-340 signature verifies

Only the Python standard library is used: the secp256k1 arithmetic below is the
BIP-340 reference verification algorithm, not a protocol client.
Run it isolated (`python3 -I`).
"""

import hashlib
import json
import re
import sys

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (
    0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
    0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
)
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX128 = re.compile(r"^[0-9a-f]{128}$")


def point_add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and a[1] != b[1]:
        return None
    if a == b:
        lam = 3 * a[0] * a[0] * pow(2 * a[1], -1, P) % P
    else:
        lam = (b[1] - a[1]) * pow(b[0] - a[0], -1, P) % P
    x = (lam * lam - a[0] - b[0]) % P
    return (x, (lam * (a[0] - x) - a[1]) % P)


def point_mul(pt, k):
    result = None
    while k:
        if k & 1:
            result = point_add(result, pt)
        pt = point_add(pt, pt)
        k >>= 1
    return result


def tagged_hash(tag, msg):
    th = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(th + th + msg).digest()


def lift_x(x):
    if x >= P:
        return None
    c = (pow(x, 3, P) + 7) % P
    y = pow(c, (P + 1) // 4, P)
    if pow(y, 2, P) != c:
        return None
    return (x, y if y % 2 == 0 else P - y)


def schnorr_verify(msg, pubkey, sig):
    pt = lift_x(int.from_bytes(pubkey, "big"))
    r = int.from_bytes(sig[:32], "big")
    s = int.from_bytes(sig[32:], "big")
    if pt is None or r >= P or s >= N:
        return False
    e = int.from_bytes(tagged_hash("BIP0340/challenge", sig[:32] + pubkey + msg), "big") % N
    big_r = point_add(point_mul(G, s), point_mul(pt, N - e))
    return big_r is not None and big_r[1] % 2 == 0 and big_r[0] == r


def event_id(ev):
    serial = json.dumps(
        [0, ev["pubkey"], ev["created_at"], ev["kind"], ev["tags"], ev["content"]],
        separators=(",", ":"),
        ensure_ascii=False,
    )
    return hashlib.sha256(serial.encode("utf-8")).hexdigest()


def well_formed(ev):
    if not isinstance(ev, dict):
        return False
    for key in ("id", "pubkey"):
        if not isinstance(ev.get(key), str) or not HEX64.match(ev[key]):
            return False
    if not isinstance(ev.get("sig"), str) or not HEX128.match(ev["sig"]):
        return False
    for key in ("created_at", "kind"):
        if type(ev.get(key)) is not int or ev[key] < 0:
            return False
    if not isinstance(ev.get("content"), str):
        return False
    tags = ev.get("tags")
    if not isinstance(tags, list):
        return False
    return all(isinstance(t, list) and t and all(isinstance(v, str) for v in t) for t in tags)


def thread_refs(ev):
    """NIP-10 marked `e` tags: the root marker wins, then a lone reply marker. The
    owner's Buzz client marks every threading tag, so an event carrying no marked
    root or reply is its own thread root."""
    root = reply = None
    for t in ev["tags"]:
        if t[0] != "e" or len(t) < 4 or not HEX64.match(t[1]):
            continue
        if t[3] == "root" and root is None:
            root = t[1]
        elif t[3] == "reply" and reply is None:
            reply = t[1]
    return root or reply or ev["id"]


def candidate(ev, owner, bridge, channel, floor):
    """Every acceptance check except the signature, so the cheap ones bound the dear one."""
    if not well_formed(ev) or ev["kind"] != 9:
        return False
    if ev["pubkey"] != owner or ev["pubkey"] == bridge or ev["created_at"] < floor:
        return False
    tags = ev["tags"]
    h = [t for t in tags if t[0] == "h"]
    if len(h) != 1 or len(h[0]) < 2 or h[0][1] != channel:
        return False
    if not any(t[0] == "p" and len(t) >= 2 and t[1] == bridge for t in tags):
        return False
    if not ev["content"].strip():
        return False
    return event_id(ev) == ev["id"]


def signed(ev):
    return schnorr_verify(bytes.fromhex(ev["id"]), bytes.fromhex(ev["pubkey"]), bytes.fromhex(ev["sig"]))


def main(argv):
    args = dict(zip(argv[0::2], argv[1::2]))
    if len(argv) != 8 or set(args) != {"--owner", "--bridge", "--channel", "--floor"}:
        print("usage: fm-buzz-verify.py --owner <hex> --bridge <hex> --channel <uuid> --floor <epoch>", file=sys.stderr)
        return 2
    try:
        floor = int(args["--floor"])
        events = json.load(sys.stdin)
    except ValueError:
        print("fm-buzz-verify: malformed input", file=sys.stderr)
        return 1
    if not isinstance(events, list):
        print("fm-buzz-verify: input is not an event array", file=sys.stderr)
        return 1
    unique = {}
    for ev in events:
        if candidate(ev, args["--owner"], args["--bridge"], args["--channel"], floor):
            unique.setdefault((ev["id"], ev["sig"]), ev)
    seen = set()
    out = []
    for ev in sorted(unique.values(), key=lambda ev: (ev["created_at"], ev["id"])):
        if ev["id"] in seen or not signed(ev):
            continue
        seen.add(ev["id"])
        out.append({
            "event_id": ev["id"],
            "created_at": ev["created_at"],
            "content": ev["content"],
            "signer": ev["pubkey"],
            "parent": ev["id"],
            "thread_root": thread_refs(ev),
        })
    json.dump(out, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
