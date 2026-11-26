#!/usr/bin/env python3
"""Filter and verify Buzz Stream events for the Buzz bridge (bin/fm-buzz-poll.sh).

Usage: fm-buzz-verify.py --owner <hex> --bridge <hex> --channel <uuid> --floor <epoch>
                        [--thread-roots | --history-dir <dir> --thread-limit <n>]

Reads a JSON array of Nostr events on stdin (the pinned Buzz CLI's
`messages get --format json` output) and prints a JSON array of the accepted
owner requests, oldest first:
  {event_id, created_at, content, signer, parent, thread_root}

Signature verification is the one expensive stage and the relay is not trusted
to have checked it, so every distinct candidate the caller hands over is
verified. The input is what bounds the work, in three terms, because the caller
runs this module twice over the same page. The intake candidates, TWICE over:
bin/fm-buzz-poll.sh makes one newest-first read of at most its page limit, so an
over-budget window arrives capped at its newest events, and each of the two
processes verifies those candidates independently - nothing is shared between
them. That read is scoped by channel and kind, not by author, so the owner's
latest mention is inside it unless more than that page limit of channel messages
are newer than the mention. Then, in the second process only, the thread
histories, which `private_thread` must verify event by event before it can trust
any signer in them: at most one history per lookup the caller made, each capped at
its thread limit. So the ceiling is twice the page limit plus lookups x thread
limit, every term of it the caller's to choose. The sweep stays inside the
watcher's per-check timeout only while that sum does; raising any one of them is a
change to that budget.

The paging overlap re-delivers the same event, so candidates are deduplicated
per distinct (id, sig) pair before the signature stage. The id alone would not
do: it fixes every signed field, so a copy of a real event carrying a junk
signature shares it, and collapsing the two would let that copy displace the
owner's own message.

An event is accepted only when ALL of these hold; anything else is dropped
silently, because the bridge's contract is "drop everything else":
  - kind 9 (Stream message); edits (40003), DMs, gift wraps and other kinds drop
  - exactly one `h` tag, equal to the configured channel
  - addressed to the bridge under docs/configuration.md "Buzz bridge"
  - signer (pubkey) equals the configured owner pubkey, and is not the bridge
  - created_at at or after the age floor
  - non-empty content; an `imeta` attachment is ignored, the text is the request
  - the event id recomputes per NIP-01 and the BIP-340 signature verifies

Only the Python standard library is used: the secp256k1 arithmetic below is the
BIP-340 reference verification algorithm, not a protocol client.
Run it isolated (`python3 -I`).

`--thread-roots` prints one `<thread root> <event id>` line per candidate worth
looking up, newest first; the caller groups them, since only it can tell which
events it has already handled. Only signature-verified candidates are listed: the
caller's lookup budget is scarce, and the event id fixes every signed field but is
itself recomputable by anyone, so an unsigned copy attributed to the owner would
otherwise crowd a real reply's thread out of that budget and drop it silently.
`--history-dir` supplies one completed `messages thread` result per root, using
the root id as the filename. A result at the requested limit may be truncated.
Any event among the ones that read returned that is not provably the owner's or
the bridge's closes the thread to implicit intake, so a read that over-returns
makes the feature inert rather than wrong.
"""

import argparse
import hashlib
import json
from pathlib import Path
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
    try:
        return hashlib.sha256(serial.encode("utf-8")).hexdigest()
    except UnicodeEncodeError:
        return None


def well_formed(ev):
    if not isinstance(ev, dict):
        return False
    for key in ("id", "pubkey"):
        if not isinstance(ev.get(key), str) or not HEX64.fullmatch(ev[key]):
            return False
    if not isinstance(ev.get("sig"), str) or not HEX128.fullmatch(ev["sig"]):
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
        if t[0] != "e" or len(t) < 4 or not HEX64.fullmatch(t[1]):
            continue
        if t[3] == "root" and root is None:
            root = t[1]
        elif t[3] == "reply" and reply is None:
            reply = t[1]
    return root or reply or ev["id"]


def in_channel(ev, channel):
    h = [t for t in ev["tags"] if t[0] == "h"]
    return len(h) == 1 and len(h[0]) >= 2 and h[0][1] == channel


def mentions(ev, owner):
    """`p` tags naming anyone but the owner. A client replying to one's own
    earlier message tags the owner as a participant; being addressed to oneself
    does not make a message meant for somebody else."""
    return {t[1] for t in ev["tags"] if t[0] == "p" and len(t) >= 2 and t[1] != owner}


def candidate(ev, owner, bridge, channel, floor):
    """Screen intake events before checking signatures and thread history."""
    if not well_formed(ev) or ev["kind"] != 9:
        return False
    if ev["pubkey"] != owner or ev["pubkey"] == bridge or ev["created_at"] < floor:
        return False
    if not ev["content"].strip():
        return False
    if not in_channel(ev, channel):
        return False
    addressees = mentions(ev, owner)
    if bridge not in addressees and (addressees or thread_refs(ev) == ev["id"]):
        return False
    return event_id(ev) == ev["id"]


def signed(ev):
    return schnorr_verify(bytes.fromhex(ev["id"]), bytes.fromhex(ev["pubkey"]), bytes.fromhex(ev["sig"]))


def private_thread(path, root, args):
    """Return the signed member IDs and earliest bridge reply in a complete thread.

    The relay scoped this read to one thread, so every event it returned is a
    participant: a third party disqualifies the thread whatever its tags say. The
    `h` and `e` tags decide membership and the first bridge reply, never whether
    somebody else is present. Reading them the other way round would let anyone
    join unnoticed, because every shape this module calls malformed - a duplicated
    or absent `h` tag, NIP-10's deprecated positional `e` form, a reply marker
    naming a descendant - would then read as absence rather than as a stranger.
    Only the signer is load-bearing here, and only the signature attests it, so an
    event whose id or signature does not verify closes the thread as well: nothing
    says it is the owner's or the bridge's, and a post beside the owner that cannot
    be attributed is the very thing rule 3 is about. The owner's explicit mention
    still reaches such a thread, which is the documented way through.
    """
    try:
        with path.open(encoding="utf-8") as stream:
            events = json.load(stream)
    except (OSError, ValueError):
        return set(), None
    if not isinstance(events, list) or len(events) >= args.thread_limit:
        return set(), None
    members = set()
    first_reply = None
    for ev in events:
        if not well_formed(ev):
            return set(), None
        if ev["id"] in members:
            continue
        if event_id(ev) != ev["id"] or not signed(ev) or ev["pubkey"] not in (args.owner, args.bridge):
            return set(), None
        if not in_channel(ev, args.channel) or thread_refs(ev) != root:
            continue
        members.add(ev["id"])
        if ev["pubkey"] == args.bridge and ev["kind"] == 9 and ev["id"] != root:
            if first_reply is None or ev["created_at"] < first_reply:
                first_reply = ev["created_at"]
    if root not in members:
        return set(), None
    return members, first_reply


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--owner", required=True)
    parser.add_argument("--bridge", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--floor", required=True, type=int)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--thread-roots", action="store_true")
    mode.add_argument("--history-dir", type=Path)
    parser.add_argument("--thread-limit", type=int)
    args = parser.parse_args(argv)
    if args.history_dir and not args.thread_limit:
        parser.error("--history-dir requires --thread-limit")
    try:
        events = json.load(sys.stdin)
    except ValueError:
        print("fm-buzz-verify: malformed input", file=sys.stderr)
        return 1
    if not isinstance(events, list):
        print("fm-buzz-verify: input is not an event array", file=sys.stderr)
        return 1
    unique = {}
    for ev in events:
        if candidate(ev, args.owner, args.bridge, args.channel, args.floor):
            unique.setdefault((ev["id"], ev["sig"]), ev)
    ordered = sorted(unique.values(), key=lambda ev: (ev["created_at"], ev["id"]))
    if args.thread_roots:
        for ev in reversed(ordered):
            if not mentions(ev, args.owner) and signed(ev):
                print(thread_refs(ev), ev["id"])
        return 0

    histories = {}
    seen = set()
    out = []
    for ev in ordered:
        if ev["id"] in seen:
            continue
        root = thread_refs(ev)
        if args.bridge not in mentions(ev, args.owner):
            if args.history_dir is None:
                continue
            if root not in histories:
                histories[root] = private_thread(args.history_dir / root, root, args)
            members, first_reply = histories[root]
            if ev["id"] not in members or first_reply is None or first_reply >= ev["created_at"]:
                continue
        if not signed(ev):
            continue
        seen.add(ev["id"])
        out.append({
            "event_id": ev["id"],
            "created_at": ev["created_at"],
            "content": ev["content"],
            "signer": ev["pubkey"],
            "parent": ev["id"],
            "thread_root": root,
        })
    json.dump(out, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
