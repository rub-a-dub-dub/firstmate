#!/usr/bin/env python3
"""Test-only signer for invented Buzz fixture events (tests/fm-buzz-bridge.test.sh).

Usage: buzz-sign.py pubkey <secret-hex>
       buzz-sign.py event <secret-hex> <created_at> <kind> <tags-json> <content>
       buzz-sign.py forge <pubkey-hex> <created_at> <kind> <tags-json> <content> <count>

`forge` prints a JSON array of <count> events attributed to a pubkey whose secret
the fixture does not hold: the ids recompute, so they pass every cheap acceptance
check, but the signatures are junk. It stands in for a relay that serves events it
never verified.

Reuses the curve arithmetic in bin/fm-buzz-verify.py and adds BIP-340 signing
with zero auxiliary randomness, so fixtures are deterministic. Never used with a
real key.
"""

import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "fm_buzz_verify", os.path.join(HERE, "..", "..", "bin", "fm-buzz-verify.py")
)
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


def xonly(d):
    return v.point_mul(v.G, d)[0].to_bytes(32, "big")


def sign(d0, msg):
    pt = v.point_mul(v.G, d0)
    d = d0 if pt[1] % 2 == 0 else v.N - d0
    t = (d ^ int.from_bytes(v.tagged_hash("BIP0340/aux", bytes(32)), "big")).to_bytes(32, "big")
    px = pt[0].to_bytes(32, "big")
    k0 = int.from_bytes(v.tagged_hash("BIP0340/nonce", t + px + msg), "big") % v.N
    r = v.point_mul(v.G, k0)
    k = k0 if r[1] % 2 == 0 else v.N - k0
    rx = r[0].to_bytes(32, "big")
    e = int.from_bytes(v.tagged_hash("BIP0340/challenge", rx + px + msg), "big") % v.N
    return rx + ((k + e * d) % v.N).to_bytes(32, "big")


def main(argv):
    if argv[0] == "forge":
        out = []
        for i in range(int(argv[6])):
            ev = {
                "pubkey": argv[1],
                "created_at": int(argv[2]) + i,
                "kind": int(argv[3]),
                "tags": json.loads(argv[4]),
                "content": "%s %d" % (argv[5], i),
            }
            ev["id"] = v.event_id(ev)
            ev["sig"] = "0" * 128
            out.append(ev)
        print(json.dumps(out, ensure_ascii=False))
        return 0
    d = int(argv[1], 16)
    if argv[0] == "pubkey":
        print(xonly(d).hex())
        return 0
    ev = {
        "pubkey": xonly(d).hex(),
        "created_at": int(argv[2]),
        "kind": int(argv[3]),
        "tags": json.loads(argv[4]),
        "content": argv[5],
    }
    ev["id"] = v.event_id(ev)
    ev["sig"] = sign(d, bytes.fromhex(ev["id"])).hex()
    assert v.schnorr_verify(bytes.fromhex(ev["id"]), bytes.fromhex(ev["pubkey"]), bytes.fromhex(ev["sig"]))
    print(json.dumps(ev, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
