#!/usr/bin/env bash
# check_all.sh -- run the repository's unit, vector, and EEST checks against
# the main guest (ZisK accelerators through the FFI stubs).
#
# Every command is captured in work/check-all/*.log so a noisy oracle or
# emulator cannot hide the one-line PASS/FAIL status printed by this script.
# The script deliberately continues after a failure and exits non-zero if any
# check failed.
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOG_DIR="${CHECK_ALL_LOG_DIR:-$ROOT/work/check-all}"
mkdir -p "$LOG_DIR"

PASS_COUNT=0
FAIL_COUNT=0

# Keep one overridable runner for all checks.  This is useful when the evm-asm
# submodule is mounted elsewhere and also makes the Spike-first local workflow
# explicit.
SPIKE_RUN="${SPIKE_RUN:-$ROOT/tools/spike/spike_run}"
export SPIKE_RUN

run_check() {
  local name="$1"
  shift
  local slug
  slug="$(printf '%s' "$name" | tr -cs '[:alnum:]._-' '_')"
  local log="$LOG_DIR/$slug.log"
  local rc
  if "$@" >"$log" 2>&1; then
    printf 'PASS  %s\n' "$name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    rc=$?
    printf 'FAIL  %s (exit %s; see %s)\n' "$name" "$rc" "$log"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# The EEST conversion is intentionally conditional: a checkout with an
# existing manifest must be reproducible, while a fresh checkout gets the
# same small baseline used by the README.  Override the latter with
# CHECK_ALL_INPUT_COUNT when a larger sweep is desired.
INPUT_MANIFEST="$ROOT/work/inputs/manifest.tsv"
if [[ ! -f "$INPUT_MANIFEST" ]]; then
  run_check "generate EEST inputs" \
    "$ROOT/tools/make-inputs.sh" "${CHECK_ALL_INPUT_COUNT:-30}"
fi

if [[ -f "$INPUT_MANIFEST" ]]; then
  UNIT_INPUT="$(awk -F '\t' 'NF >= 2 { print $2; exit }' "$INPUT_MANIFEST")"
  if [[ "$UNIT_INPUT" != /* ]]; then
    UNIT_INPUT="$ROOT/$UNIT_INPUT"
  fi
  run_check "locate unit-test input" test -f "$UNIT_INPUT"
else
  UNIT_INPUT="$ROOT/work/check-all/missing.input"
  run_check "locate unit-test input" false
fi

# Build the fixed-path main guest before running the end-to-end checks.
run_check "build guest" "$ROOT/tools/build_guest.sh"

# The Lean side: the Guest library (generated ASTs, step-bound proofs) must build
# against the current guest sources, and the byte-level accelerator
# specifications must agree with reference values.
run_check "lean: lake build Guest" lake build Guest
run_check "lean: accel-ffi-check" lake exe accel-ffi-check
run_check "lean: input-arena-check" lake exe input-arena-check
run_check "accelerator foreign-call smoke (ziskemu)" python3 "$ROOT/tools/accel-ffi-smoke.py"

run_unit_tests() {
  run_check "unit t_globals" \
    env SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
    "$ROOT/guest/test/t_globals.pnk" "$UNIT_INPUT" \
    "struct.pack('<QQQQQQQQ', 0xa1000000, 0xa1000000, 0xa1000040, 1234, 5678, 0xa1000040, 0xa10f4280, 1234)"
  run_check "unit t_keccak" \
    env SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
    "$ROOT/guest/test/t_keccak.pnk" "$UNIT_INPUT" \
    "keccak256(blob) + keccak256(b'') + keccak256(blob[:min(len(blob),200)]) + keccak256(blob[:min(len(blob),136)]) + keccak256(blob[:min(len(blob),135)]) + keccak256(blob[1:1+min(len(blob),201)-1])"
  run_check "unit t_sha256" \
    env SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
    "$ROOT/guest/test/t_sha256.pnk" "$UNIT_INPUT" \
    "hashlib.sha256(blob).digest() + hashlib.sha256(hashlib.sha256(blob).digest() * 2).digest()"
  run_check "unit t_header" \
    env SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
    "$ROOT/guest/test/t_header.pnk" "$UNIT_INPUT" @guest/test/exp_header.py
  run_check "unit t_tx" \
    env SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
    "$ROOT/guest/test/t_tx.pnk" "$UNIT_INPUT" @guest/test/exp_tx.py
  run_check "unit t_tx_neg" \
    env SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
    "$ROOT/guest/test/t_tx_neg.pnk" "$UNIT_INPUT" @guest/test/exp_tx_neg.py
  run_check "unit t_ripemd160" \
    env SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
    "$ROOT/guest/test/t_ripemd160.pnk" "$UNIT_INPUT" @guest/test/exp_ripemd160.py
  run_check "unit t_blake2f" \
    env SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
    "$ROOT/guest/test/t_blake2f.pnk" "$PRE_DIR/blake2f.in" @guest/test/exp_blake2f.py
  run_check "unit t_modexp" \
    env SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
    "$ROOT/guest/test/t_modexp.pnk" "$PRE_DIR/modexp.in" @guest/test/exp_modexp.py
  run_check "unit t_recover" \
    env SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
    "$ROOT/guest/test/t_recover.pnk" "$UNIT_INPUT" @guest/test/exp_recover.py
  run_check "unit t_precompiles" \
    env SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
    "$ROOT/guest/test/t_precompiles.pnk" "$PRE_DIR/precompiles.in" @guest/test/exp_precompiles.py
}

# t_globals has no data dependency, but unit.py still needs a framed input.
# The expected pointers use the fixed heap base from guest/runtime/start.S.
# The vector-backed unit tests use the same Python oracles for each build.
PRE_DIR="$ROOT/work/check-all/pre"
run_check "generate precompile vectors" \
  python3 "$ROOT/tools/gen_pre_vectors.py" "$PRE_DIR"
run_check "generate precompile wrapper vectors" \
  python3 "$ROOT/tools/gen_precompile_vectors.py" "$PRE_DIR/precompiles.in"

run_unit_tests

# The aggregate M1 source is a compile smoke check: it has no oracle.
run_check "compile t_m1_all" \
  "$ROOT/guest/build.sh" "$ROOT/guest/test/t_m1_all.pnk" \
  "$LOG_DIR/t_m1_all.elf"

for script in check_u256.sh check_rlp.sh check_mpt.sh check_secp256k1.sh check_p256.sh; do
  run_check "vector ${script%.sh}" "$ROOT/tools/$script"
done
run_check "vector check_bls12381" \
  "$ROOT/tools/check_bls12381.sh"
run_check "vector check_bn254" \
  "$ROOT/tools/check_bn254.sh" --only 1,2
run_check "vector check_kzg" \
  "$ROOT/tools/check_kzg.sh"

run_eest_with_baseline() {
  local elf="$1"
  local manifest="$2"
  local json="$3"
  shift 3
  local runner_rc=0
  "$ROOT/tools/eest-run.py" "$elf" "$manifest" "$@" \
    --json "$json" || runner_rc=$?
  # eest-run returns 1 when a fixture has an expected baseline failure.  The
  # baseline checker decides whether that failure is still allowed; setup and
  # runner errors (2+) remain hard failures.
  if (( runner_rc > 1 )); then
    return "$runner_rc"
  fi
  if [[ ! -s "$json" ]]; then
    return 1
  fi
  "$ROOT/tools/eest-baseline.py" check "$manifest" "$json"
}

run_eest_variant() {
  local elf="$1"
  local manifest="$2"
  local out_dir="$3"
  local json="$4"
  local -a args=(--quiet-passes --out-dir "$out_dir")
  if [[ -n "${CHECK_ALL_EEST_JOBS:-}" ]]; then
    args+=(--jobs "$CHECK_ALL_EEST_JOBS")
  fi
  run_eest_with_baseline "$elf" "$manifest" "$json" "${args[@]}"
}

# Fixtures recorded as allowed failures in tools/eest-baseline.json for this
# manifest (e.g. spike step-cap exits) are skipped: their output is not
# comparable between emulators.
baseline_allowed_labels() {
  python3 - "$ROOT/tools/eest-baseline.json" "$1" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except OSError:
    sys.exit(0)
entry = data.get("manifests", data).get(sys.argv[2], {})
for label in (entry.get("failures") or {}):
    print(label)
PY
}

compare_eest_outputs() {
  local manifest="$1"
  local first_dir="$2"
  local second_dir="$3"
  local manifest_name
  manifest_name="$(basename "$(dirname "$manifest")")"
  local allowed
  allowed="$(baseline_allowed_labels "$manifest_name")"
  local checked=0
  local skipped=0
  local failures=0
  local label remainder first second
  while IFS=$'\t' read -r label remainder; do
    [[ -n "$label" ]] || continue
    if grep -qxF -- "$label" <<<"$allowed"; then
      skipped=$((skipped + 1))
      continue
    fi
    first="$first_dir/$label.output"
    second="$second_dir/$label.output"
    checked=$((checked + 1))
    if [[ ! -f "$first" || ! -f "$second" ]]; then
      printf 'missing output for %s\n' "$label"
      failures=$((failures + 1))
    elif ! cmp -s "$first" "$second"; then
      printf 'output differs for %s\n' "$label"
      failures=$((failures + 1))
    fi
  done < "$manifest"
  if (( failures == 0 )); then
    printf 'PASS (%s EEST output files byte-identical, %s baseline-allowed failures skipped)\n' "$checked" "$skipped"
    return 0
  fi
  printf 'FAIL (%s of %s EEST output files differ or are missing)\n' \
    "$failures" "$checked"
  return 1
}

# Run every converted EEST manifest, including sampled manifests such as
# work/inputs-rand/manifest.tsv when present, against the main guest.  The
# output directories are kept so the Spike/ziskemu byte-for-byte differential
# below is independent of the PASS/FAIL classification.
manifest_found=0
BASE_MANIFEST=""
BASE_SPIKE_DIR=""
for manifest in "$ROOT"/work/inputs*/manifest.tsv; do
  [[ -f "$manifest" ]] || continue
  manifest_found=1
  manifest_name="$(basename "$(dirname "$manifest")")"
  out_dir="$LOG_DIR/eest-${manifest_name}"
  out_json="$LOG_DIR/eest-${manifest_name}.json"
  run_check "EEST $manifest_name" \
    run_eest_variant "$ROOT/guest/build/guest.elf" "$manifest" \
    "$out_dir" "$out_json"
  if [[ "$manifest_name" == "inputs" ]]; then
    BASE_MANIFEST="$manifest"
    BASE_SPIKE_DIR="$out_dir"
  fi
done
if [[ "$manifest_found" -eq 0 ]]; then
  run_check "EEST manifests available" false
fi

# ziskemu is deliberately opt-in for the local Spike-first workflow because
# it is substantially slower.  CI or a release check can enable the exact
# requested parity gate with CHECK_ALL_ZISKE_PARITY=1.
if [[ -n "$BASE_MANIFEST" ]]; then
  if [[ "${CHECK_ALL_ZISKE_PARITY:-0}" == "1" ]]; then
    ZISK_DIR="$LOG_DIR/eest-inputs-ziskemu"
    ZISK_JSON="$LOG_DIR/eest-inputs-ziskemu.json"
    run_check "EEST inputs ziskemu" \
      run_eest_with_baseline "$ROOT/guest/build/guest.elf" \
      "$BASE_MANIFEST" "$ZISK_JSON" --quiet-passes --ziskemu \
      --out-dir "$ZISK_DIR"
    run_check "EEST inputs Spike/ziskemu byte differential" \
      compare_eest_outputs "$BASE_MANIFEST" "$BASE_SPIKE_DIR" "$ZISK_DIR"
  else
    printf 'SKIP  EEST inputs ziskemu (set CHECK_ALL_ZISKE_PARITY=1)\n'
  fi
fi

printf '%s\n' '----------------------------------------'
printf 'Summary: %s PASS, %s FAIL\n' "$PASS_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
  exit 1
fi
