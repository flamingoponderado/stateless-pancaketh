#!/usr/bin/env python3
"""accel-ffi-smoke.py -- run guest/test/accel_ffi_smoke.pnk (one @keccakf and one
@sha256f call in the foreign-call convention of docs/ACCEL-FFI.md) on the
ZISK_ACCEL build under ziskemu and compare its output with hashlib:

  bytes  0..32  Keccak-f of the SHA3-256 padding block of the empty message, whose
                first 32 bytes are the SHA3-256 digest of the empty message
  bytes 32..64  the packed SHA-256 state after one compression of the padded block
                of "abc", i.e. SHA-256("abc") as eight big-endian words, two per
                little-endian 64-bit cell (low word first)
"""
import hashlib, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZISKEMU = os.environ.get("ZISKEMU", os.path.expanduser("~/.zisk/bin/ziskemu"))

def expected():
    digest = hashlib.sha256(b"abc").digest()
    w = [int.from_bytes(digest[4 * i:4 * i + 4], "big") for i in range(8)]
    packed = b"".join((w[2 * i] | (w[2 * i + 1] << 32)).to_bytes(8, "little") for i in range(4))
    return hashlib.sha3_256(b"").digest() + packed

def main():
    with tempfile.TemporaryDirectory() as tmp:
        elf, inp, out = (os.path.join(tmp, n) for n in ("smoke.elf", "in.bin", "out.bin"))
        env = dict(os.environ, ACCEL="1")
        subprocess.run([os.path.join(ROOT, "guest/build.sh"),
                        os.path.join(ROOT, "guest/test/accel_ffi_smoke.pnk"), elf],
                       check=True, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(inp, "wb") as f:
            f.write((0).to_bytes(8, "little"))      # empty blob, ziskemu input framing
        subprocess.run([ZISKEMU, "-e", elf, "-i", inp, "-o", out],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        actual = open(out, "rb").read()[:64]
    want = expected()
    if actual == want:
        print("PASS  accelerator foreign-call smoke test (keccakf, sha256f)")
        return 0
    print("FAIL  accelerator foreign-call smoke test")
    print("  expected:", want.hex())
    print("  actual:  ", actual.hex())
    return 1

if __name__ == "__main__":
    sys.exit(main())
