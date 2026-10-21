#!/usr/bin/env bash
# check_kzg.sh [--steps]
# Generate execution-specs-backed KZG vectors and compare software and
# accelerator builds under Spike.  --steps reports one Spike count per case.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/work/kzg"
mkdir -p "$W"

if [ -n "${BLS_PYTHON:-}" ]; then
  PY=("$BLS_PYTHON")
elif [ -n "${VIRTUAL_ENV:-}" ] && [ -x "$VIRTUAL_ENV/bin/python" ]; then
  PY=("$VIRTUAL_ENV/bin/python")
elif [ -x "$ROOT/evm-asm/execution-specs/.venv/bin/python" ]; then
  PY=("$ROOT/evm-asm/execution-specs/.venv/bin/python")
else
  PY=(uv run --directory "$ROOT/evm-asm/execution-specs" python)
fi

"${PY[@]}" "$ROOT/tools/gen_kzg_vectors.py" "$W/kzg.in" "$W/kzg.expected"

SPIKE_RUN="${SPIKE_RUN:-$ROOT/tools/spike/spike_run}"
ELF_SW="$W/t_kzg_sw.elf"
ELF_ACCEL="$W/t_kzg_accel.elf"
"$ROOT/guest/build.sh" "$ROOT/guest/test/t_kzg.pnk" "$ELF_SW" >/dev/null
ACCEL=1 "$ROOT/guest/build.sh" "$ROOT/guest/test/t_kzg.pnk" "$ELF_ACCEL" >/dev/null

run_one() {
  local name="$1" elf="$2"
  local out="$W/t_kzg_${name}.out"
  local log="$W/t_kzg_${name}.spike.log"
  SPIKE_OUTPUT_LEN=65536 "$SPIKE_RUN" "$elf" "$W/kzg.in" "$out" > /dev/null 2>"$log"
  tail -n 1 "$log"
  local n
  n=$(stat -c %s "$W/kzg.expected")
  head -c "$n" "$out" > "$W/t_kzg_${name}.actual"
  cmp "$W/t_kzg_${name}.actual" "$W/kzg.expected"
  echo "PASS ($name)"
}

run_one sw "$ELF_SW"
run_one accel "$ELF_ACCEL"
cmp "$W/t_kzg_sw.actual" "$W/t_kzg_accel.actual"
echo "PASS (software/accelerated Spike differential)"

if [ "${1:-}" = "--steps" ]; then
  python3 - "$W/kzg.in" "$W" <<'PY'
import struct
import sys

packed = open(sys.argv[1], "rb").read()
n = struct.unpack_from("<Q", packed)[0]
blob = packed[8:8 + n]
pos = 0
while pos + 16 <= len(blob):
    ty, length = struct.unpack_from("<QQ", blob, pos)
    end = pos + 16 + ((length + 7) & ~7)
    if end > len(blob):
        break
    record = blob[pos:end]
    with open(f"{sys.argv[2]}/case_{ty}.in", "wb") as out:
        out.write(struct.pack("<Q", len(record)) + record)
    pos = end
PY
  for case in 1 2 3 4 5 6 7; do
    input="$W/case_${case}.in"
    [ -f "$input" ] || continue
    for variant in sw accel; do
      log="$W/case_${case}_${variant}.steps.log"
      SPIKE_OUTPUT_LEN=65536 "$SPIKE_RUN" "$W/t_kzg_${variant}.elf" "$input" \
        "$W/case_${case}_${variant}.out" > /dev/null 2>"$log"
      printf 'steps case %-2s %-6s ' "$case" "$variant"
      tail -n 1 "$log"
    done
  done
fi
