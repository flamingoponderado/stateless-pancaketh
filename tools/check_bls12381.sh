#!/usr/bin/env bash
# check_bls12381.sh [--seed S] [--only TYPES] [--steps]
# Generate BLS12-381 vectors, run the software and accelerator builds under
# Spike, and compare both byte-for-byte with the same py_ecc oracle.  --steps
# runs the first record of each operation type separately and reports both
# instruction counts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED=1
ONLY=""
STEPS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --seed) SEED="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    --steps) STEPS=1; shift;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done

W="$ROOT/work/bls12381"
mkdir -p "$W"
TAG="$SEED"
if [ -n "$ONLY" ]; then
  TAG="${TAG}_${ONLY//,/_}"
fi
INP="$W/bls_${TAG}.in"
EXP="$W/bls_${TAG}.expected"
# Most checkouts have the execution-specs submodule populated and can use uv
# directly.  BLS_PYTHON is an optional escape hatch for an already-created
# execution-specs virtualenv when that submodule directory is empty.
if [ -n "${BLS_PYTHON:-}" ]; then
  PY=("$BLS_PYTHON")
elif [ -n "${VIRTUAL_ENV:-}" ] && [ -x "$VIRTUAL_ENV/bin/python" ]; then
  PY=("$VIRTUAL_ENV/bin/python")
elif [ -x "$ROOT/evm-asm/execution-specs/.venv/bin/python" ]; then
  PY=("$ROOT/evm-asm/execution-specs/.venv/bin/python")
else
  PY=(uv run --directory "$ROOT/evm-asm/execution-specs" python)
fi
GEN_ARGS=(--seed "$SEED")
if [ -n "$ONLY" ]; then
  GEN_ARGS+=(--only "$ONLY")
fi
"${PY[@]}" "$ROOT/tools/gen_bls12381_vectors.py" "${GEN_ARGS[@]}" "$INP" "$EXP"

SPIKE_RUN="${SPIKE_RUN:-$ROOT/tools/spike/spike_run}"
ELF_SW="$W/t_bls12381_${TAG}_sw.elf"
ELF_ACCEL="$W/t_bls12381_${TAG}_accel.elf"
"$ROOT/guest/build.sh" "$ROOT/guest/test/t_bls12381.pnk" "$ELF_SW" >/dev/null
ACCEL=1 "$ROOT/guest/build.sh" "$ROOT/guest/test/t_bls12381.pnk" "$ELF_ACCEL" >/dev/null

run_one() {
  local tag="$1" elf="$2"
  local out="$W/t_bls12381_${TAG}_${tag}.out"
  local log="$W/t_bls12381_${TAG}_${tag}.spike.log"
  if ! SPIKE_OUTPUT_LEN=65536 "$SPIKE_RUN" "$elf" "$INP" "$out" > /dev/null 2>"$log"; then
    cat "$log" >&2
    return 1
  fi
  tail -n 1 "$log"
  local n
  n=$(stat -c %s "$EXP")
  head -c "$n" "$out" > "$W/t_bls12381_${TAG}_${tag}.actual"
  if cmp -s "$W/t_bls12381_${TAG}_${tag}.actual" "$EXP"; then
    echo "PASS ($tag)"
    return 0
  fi
  echo "FAIL ($tag): first differing bytes" >&2
  python3 - "$W/t_bls12381_${TAG}_${tag}.actual" "$EXP" <<'PY'
import sys
act, exp = (open(p, "rb").read() for p in sys.argv[1:])
for off in range(min(len(act), len(exp))):
    if act[off] != exp[off]:
        print(f"offset {off}: expected {exp[off]:02x}, actual {act[off]:02x}")
        break
else:
    print(f"length: expected {len(exp)}, actual {len(act)}")
PY
  return 1
}

run_one sw "$ELF_SW"
run_one accel "$ELF_ACCEL"
SW_ACTUAL="$W/t_bls12381_${TAG}_sw.actual"
ACCEL_ACTUAL="$W/t_bls12381_${TAG}_accel.actual"
if cmp -s "$SW_ACTUAL" "$ACCEL_ACTUAL"; then
  echo "PASS (software/accelerated Spike differential)"
else
  echo "FAIL (software/accelerated Spike differential)" >&2
  cmp "$SW_ACTUAL" "$ACCEL_ACTUAL" || true
  exit 1
fi

if [ -n "$STEPS" ]; then
  python3 - "$INP" "$W" "$TAG" <<'PY'
import os, struct, sys
packed = open(sys.argv[1], "rb").read()
n = struct.unpack_from("<Q", packed)[0]
blob = packed[8:8+n]
seen = set()
pos = 0
while pos + 16 <= len(blob):
    ty, length = struct.unpack_from("<QQ", blob, pos)
    end = pos + 16 + ((length + 7) & ~7)
    if end > len(blob):
        break
    if ty not in seen:
        step = blob[pos:end]
        tag = sys.argv[3]
        path = os.path.join(sys.argv[2], f"step_{tag}_{ty}.in")
        open(path, "wb").write(struct.pack("<Q", len(step)) + step)
        seen.add(ty)
    pos = end
print(" ".join(str(x) for x in sorted(seen)))
PY
  for ty in 1 2 3 4 5 6 7 8 9 10 11; do
    step="$W/step_${TAG}_${ty}.in"
    [ -f "$step" ] || continue
    printf 'steps type %-2s software:   ' "$ty"
    SPIKE_OUTPUT_LEN=65536 "$SPIKE_RUN" "$ELF_SW" "$step" "$W/step_sw.out" 2>&1 | tail -1
    printf 'steps type %-2s accelerated: ' "$ty"
    SPIKE_OUTPUT_LEN=65536 "$SPIKE_RUN" "$ELF_ACCEL" "$step" "$W/step_accel.out" 2>&1 | tail -1
  done
fi
