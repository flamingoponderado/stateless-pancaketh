#!/usr/bin/env bash
# eest-spike-full.sh
# Run the guest against the ENTIRE tests-zkevm EEST fixture corpus under
# Spike with the accelerated guest -- not the small tools/check_all.sh
# sample. See docs/EEST-SPIKE.md.
#
# The output directory is named with the source commit so that result files
# cannot be mistaken for a run from another checkout. Re-running the command
# with the same directory reuses its manifest.
set -u -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RESULT_COMMIT="$(git rev-parse HEAD)"
TAG="$(tr -d '[:space:]' < eest-fixture-tag.txt)"
SPIKE_RUN="${SPIKE_RUN:-$ROOT/tools/spike/spike_run}"
JOBS="${EEST_JOBS:-32}"
RUN_ROOT="$ROOT/work/eest-spike-$RESULT_COMMIT"

test -x "$SPIKE_RUN" || {
  echo "spike_run not found/executable at $SPIKE_RUN" >&2
  echo "(see README.md's Quick start to build it)" >&2
  exit 1
}

evm-asm/scripts/eest-fetch-fixtures.sh "$TAG"
tools/make-inputs.sh --all "$RUN_ROOT/inputs"
ACCEL=1 guest/build.sh guest/src/main.pnk "$RUN_ROOT/guest-accel.elf"

set +e
SPIKE_RUN="$SPIKE_RUN" python3 tools/eest-run.py \
  "$RUN_ROOT/guest-accel.elf" "$RUN_ROOT/inputs/manifest.tsv" \
  --jobs "$JOBS" --quiet-passes \
  --json "$RUN_ROOT/results.json" --out-dir "$RUN_ROOT/run-accel"
RUN_RC=$?
set -e

python3 - "$RUN_ROOT/results.json" <<'PY'
import collections
import json
import sys

results = json.load(open(sys.argv[1], encoding="utf-8"))
counts = collections.Counter(record["class"] for record in results)
print(f"records: {len(results)}")
for name in ("PASS(full)", "PASS(malformed)", "FAIL", "ERROR"):
    if counts[name]:
        print(f"{name}: {counts[name]}")
PY
printf 'eest-run exit: %s\n' "$RUN_RC"
exit "$RUN_RC"
