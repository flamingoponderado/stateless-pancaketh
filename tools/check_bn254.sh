#!/usr/bin/env bash
# check_bn254.sh [--seed S] [--pairings N] [--only TYPES] [--steps]
# Generate alt_bn128 vectors (tools/gen_bn254_vectors.py, py_ecc oracle under the
# execution-specs uv env), build software and ZISK_ACCEL guest/test/t_bn254.pnk
# ELFs, run both under spike_run, and compare their output records with the
# oracle and each other.  --steps additionally times single-record inputs
# (ECADD, ECMUL, 1- and 2-pair pairing checks, empty).  If the software
# aggregate reaches Spike's fixed safety cap, the records are checked one at a
# time so the reference path remains covered.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED=1; PAIRINGS=-1; ONLY=""; STEPS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --seed) SEED="$2"; shift 2;;
    --pairings) PAIRINGS="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    --steps) STEPS=1; shift;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done
W="$ROOT/work/bn254"; mkdir -p "$W"
TAG="$SEED"
if [ "$PAIRINGS" -ge 0 ]; then
  TAG="${TAG}_p${PAIRINGS}"
fi
if [ -n "$ONLY" ]; then
  TAG="${TAG}_${ONLY//,/_}"
fi
PY=(uv run --directory "$ROOT/evm-asm/execution-specs" python)
INP="$W/bn254_${TAG}.in"; EXP="$W/bn254_${TAG}.expected"
GEN_ARGS=(--seed "$SEED" --pairings "$PAIRINGS")
if [ -n "$ONLY" ]; then
  GEN_ARGS+=(--only "$ONLY")
fi
"${PY[@]}" "$ROOT/tools/gen_bn254_vectors.py" "${GEN_ARGS[@]}" "$INP" "$EXP"
ELF_SW="$W/t_bn254_${TAG}_sw.elf"
ELF_ACCEL="$W/t_bn254_${TAG}_accel.elf"
env -u ACCEL "$ROOT/guest/build.sh" "$ROOT/guest/test/t_bn254.pnk" "$ELF_SW" > /dev/null
ACCEL=1 "$ROOT/guest/build.sh" "$ROOT/guest/test/t_bn254.pnk" "$ELF_ACCEL" > /dev/null
SPIKE_RUN="${SPIKE_RUN:-$ROOT/tools/spike/spike_run}"
split_check() {
  local name="$1" elf="$2"
  local prefix="$W/t_bn254_${TAG}_${name}_record"
  local actual="$W/t_bn254_${TAG}_${name}.actual"
  python3 - "$INP" "$EXP" "$prefix" <<'EOF'
import struct
import sys

inp, exp, prefix = sys.argv[1:]
packed = open(inp, "rb").read()
n = struct.unpack_from("<Q", packed)[0]
blob = packed[8:8 + n]
expected = open(exp, "rb").read()
pos = opos = index = 0
while pos < len(blob):
    ty, length = struct.unpack_from("<QQ", blob, pos)
    input_size = 16 + ((length + 7) & ~7)
    output_length = struct.unpack_from("<Q", expected, opos + 8)[0]
    output_size = 16 + ((output_length + 7) & ~7)
    with open(f"{prefix}_{index}.in", "wb") as f:
        f.write(struct.pack("<Q", input_size))
        f.write(blob[pos:pos + input_size])
    with open(f"{prefix}_{index}.expected", "wb") as f:
        f.write(expected[opos:opos + output_size])
    pos += input_size
    opos += output_size
    index += 1
print(index)
EOF
  : > "$actual"
  local record=0
  while [ -f "${prefix}_${record}.in" ]; do
    local record_out="${prefix}_${record}.out"
    local record_actual="${prefix}_${record}.actual"
    local record_expected="${prefix}_${record}.expected"
    if ! SPIKE_OUTPUT_LEN=262144 "$SPIKE_RUN" "$elf" \
        "${prefix}_${record}.in" "$record_out" > /dev/null 2>"${prefix}_${record}.spike.log"; then
      cat "${prefix}_${record}.spike.log" >&2
      return 1
    fi
    head -c "$(stat -c %s "$record_expected")" "$record_out" > "$record_actual"
    if ! cmp -s "$record_actual" "$record_expected"; then
      echo "FAIL ($name record $record): split Spike output differs" >&2
      return 1
    fi
    cat "$record_actual" >> "$actual"
    record=$((record + 1))
  done
  echo "PASS ($name; aggregate Spike step cap, $record records checked independently)"
}

run_one() {
  local name="$1" elf="$2"
  local out="$W/t_bn254_${TAG}_${name}.out"
  local log="$W/t_bn254_${TAG}_${name}.spike.log"
  if ! SPIKE_OUTPUT_LEN=262144 "$SPIKE_RUN" "$elf" "$INP" "$out" > /dev/null 2>"$log"; then
    if grep -q "step cap reached without halt" "$log"; then
      tail -n 1 "$log"
      local split_prefix="$W/t_bn254_${TAG}_${name}_record"
      rm -f "${split_prefix}"_*.in "${split_prefix}"_*.expected \
        "${split_prefix}"_*.out "${split_prefix}"_*.actual \
        "${split_prefix}"_*.spike.log
      split_check "$name" "$elf"
      return $?
    fi
    cat "$log" >&2
    return 1
  fi
  tail -n 1 "$log"
  local n
  n=$(stat -c %s "$EXP")
  head -c "$n" "$out" > "$W/t_bn254_${TAG}_${name}.actual"
  if cmp -s "$W/t_bn254_${TAG}_${name}.actual" "$EXP"; then
    echo "PASS ($name)"
    return 0
  fi
  echo "FAIL ($name): first differing bytes" >&2
  "${PY[@]}" - "$W/t_bn254_${TAG}_${name}.actual" "$EXP" "$INP" <<'EOF'
import sys, struct
act, exp, inp = (open(p, "rb").read() for p in sys.argv[1:4])
n = struct.unpack("<Q", inp[:8])[0]; blob = inp[8:8+n]
pos = opos = 0; idx = 0; shown = 0
while pos < len(blob):
    ty, ln = struct.unpack("<QQ", blob[pos:pos+16]); pl = blob[pos+16:pos+16+ln]
    ety, eln = struct.unpack("<QQ", exp[opos:opos+16])
    e = exp[opos+16:opos+16+eln]; a = act[opos+16:opos+16+eln]
    if act[opos:opos+16] != exp[opos:opos+16] or a != e:
        print(f"record {idx} type {ty} len {ln}: input {pl.hex()[:160]}{'...' if ln > 80 else ''}")
        print(f"  expected {e.hex()}\n  actual   {a.hex()}")
        shown += 1
        if shown >= 6: break
    pos += 16 + ((ln + 7) & ~7); opos += 16 + ((eln + 7) & ~7); idx += 1
EOF
  return 1
}

run_one sw "$ELF_SW"
run_one accel "$ELF_ACCEL"
SW_ACTUAL="$W/t_bn254_${TAG}_sw.actual"
ACCEL_ACTUAL="$W/t_bn254_${TAG}_accel.actual"
if cmp -s "$SW_ACTUAL" "$ACCEL_ACTUAL"; then
  echo "PASS (software/accelerated Spike differential)"
else
  echo "FAIL (software/accelerated Spike differential)" >&2
  cmp "$SW_ACTUAL" "$ACCEL_ACTUAL" || true
  exit 1
fi

if [ -n "$STEPS" ]; then
  "${PY[@]}" - "$INP" "$W" "$TAG" <<'EOF'
import sys, struct, os
sys.path.insert(0, os.path.join(os.path.dirname(sys.argv[1]), "..", "..", "tools"))
from gen_bn254_vectors import frame, pad8, g1_bytes, g2_bytes, neg_bytes_g1, C, R, be32
w = sys.argv[2]
g, q = g1_bytes(C.G1), g2_bytes(C.G2)
cases = {
  "empty": b"",
  "ecadd": frame(1, g + g1_bytes(C.multiply(C.G1, 2))),
  "ecmul_full_scalar": frame(2, g + be32(R - 1)),
  "pairing_1pair": frame(3, g + q),
  "pairing_2pairs": frame(3, g + q + neg_bytes_g1(g) + q),
  "pairing_2pairs_infG1": frame(3, bytes(64) + q + bytes(64) + q),
  "pairing_invalid_len": frame(3, b"\x00" * 191),
}
for name, blob in cases.items():
    open(os.path.join(w, f"step_{sys.argv[3]}_{name}.in"), "wb").write(struct.pack("<Q", len(blob)) + pad8(blob))
print(" ".join(cases))
EOF
  for name in empty ecadd ecmul_full_scalar pairing_1pair pairing_2pairs pairing_2pairs_infG1 pairing_invalid_len; do
    step="$W/step_${TAG}_${name}.in"
    [ -f "$step" ] || continue
    printf '%-24s ' "$name"
    printf 'software: '
    SPIKE_OUTPUT_LEN=4096 "$SPIKE_RUN" "$ELF_SW" "$step" "$W/step_${TAG}_sw.out" 2>&1 | tail -1
    printf '%-24s ' ""
    printf 'accelerated: '
    SPIKE_OUTPUT_LEN=4096 "$SPIKE_RUN" "$ELF_ACCEL" "$step" "$W/step_${TAG}_accel.out" 2>&1 | tail -1
  done
fi
