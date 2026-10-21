#!/usr/bin/env bash
# check_all.sh -- run the repository's unit, vector, and EEST checks against
# both the software and ZisK-accelerated main guests.
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

# Build both fixed-path main guests before running the end-to-end checks.
run_check "build software and accelerated guests" "$ROOT/tools/build_both.sh"

# The Lean side: the Guest library (generated ASTs, step-bound proofs) must build
# against the current guest sources, and the byte-level accelerator
# specifications must agree with reference values.
run_check "lean: lake build Guest" lake build Guest
run_check "lean: accel-ffi-check" lake exe accel-ffi-check
run_check "accelerator foreign-call smoke (ziskemu)" python3 "$ROOT/tools/accel-ffi-smoke.py"

run_unit_variant() {
  local variant="$1"
  if [[ "$variant" == "accelerated" ]]; then
    run_check "$variant unit t_globals" \
      env ACCEL=1 SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_globals.pnk" "$UNIT_INPUT" \
      "struct.pack('<QQQQQQQQ', 0xa1000000, 0xa1000000, 0xa1000040, 1234, 5678, 0xa1000040, 0xa10f4280, 1234)"
    run_check "$variant unit t_keccak" \
      env ACCEL=1 SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_keccak.pnk" "$UNIT_INPUT" \
      "keccak256(blob) + keccak256(b'') + keccak256(blob[:min(len(blob),200)]) + keccak256(blob[:min(len(blob),136)]) + keccak256(blob[:min(len(blob),135)]) + keccak256(blob[1:1+min(len(blob),201)-1])"
    run_check "$variant unit t_sha256" \
      env ACCEL=1 SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_sha256.pnk" "$UNIT_INPUT" \
      "hashlib.sha256(blob).digest() + hashlib.sha256(hashlib.sha256(blob).digest() * 2).digest()"
    run_check "$variant unit t_header" \
      env ACCEL=1 SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_header.pnk" "$UNIT_INPUT" @guest/test/exp_header.py
    run_check "$variant unit t_tx" \
      env ACCEL=1 SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_tx.pnk" "$UNIT_INPUT" @guest/test/exp_tx.py
    run_check "$variant unit t_tx_neg" \
      env ACCEL=1 SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_tx_neg.pnk" "$UNIT_INPUT" @guest/test/exp_tx_neg.py
    run_check "$variant unit t_ripemd160" \
      env ACCEL=1 SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_ripemd160.pnk" "$UNIT_INPUT" @guest/test/exp_ripemd160.py
    run_check "$variant unit t_blake2f" \
      env ACCEL=1 SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_blake2f.pnk" "$PRE_DIR/blake2f.in" @guest/test/exp_blake2f.py
    run_check "$variant unit t_modexp" \
      env ACCEL=1 SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_modexp.pnk" "$PRE_DIR/modexp.in" @guest/test/exp_modexp.py
    run_check "$variant unit t_recover" \
      env ACCEL=1 SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_recover.pnk" "$UNIT_INPUT" @guest/test/exp_recover.py
    run_check "$variant unit t_precompiles" \
      env ACCEL=1 SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_precompiles.pnk" "$PRE_DIR/precompiles.in" @guest/test/exp_precompiles.py
  else
    # Explicitly remove ACCEL so a caller's environment cannot make the
    # software column accidentally use the accelerated source.
    run_check "$variant unit t_globals" \
      env -u ACCEL SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_globals.pnk" "$UNIT_INPUT" \
      "struct.pack('<QQQQQQQQ', 0xa1000000, 0xa1000000, 0xa1000040, 1234, 5678, 0xa1000040, 0xa10f4280, 1234)"
    run_check "$variant unit t_keccak" \
      env -u ACCEL SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_keccak.pnk" "$UNIT_INPUT" \
      "keccak256(blob) + keccak256(b'') + keccak256(blob[:min(len(blob),200)]) + keccak256(blob[:min(len(blob),136)]) + keccak256(blob[:min(len(blob),135)]) + keccak256(blob[1:1+min(len(blob),201)-1])"
    run_check "$variant unit t_sha256" \
      env -u ACCEL SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_sha256.pnk" "$UNIT_INPUT" \
      "hashlib.sha256(blob).digest() + hashlib.sha256(hashlib.sha256(blob).digest() * 2).digest()"
    run_check "$variant unit t_header" \
      env -u ACCEL SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_header.pnk" "$UNIT_INPUT" @guest/test/exp_header.py
    run_check "$variant unit t_tx" \
      env -u ACCEL SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_tx.pnk" "$UNIT_INPUT" @guest/test/exp_tx.py
    run_check "$variant unit t_tx_neg" \
      env -u ACCEL SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_tx_neg.pnk" "$UNIT_INPUT" @guest/test/exp_tx_neg.py
    run_check "$variant unit t_ripemd160" \
      env -u ACCEL SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_ripemd160.pnk" "$UNIT_INPUT" @guest/test/exp_ripemd160.py
    run_check "$variant unit t_blake2f" \
      env -u ACCEL SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_blake2f.pnk" "$PRE_DIR/blake2f.in" @guest/test/exp_blake2f.py
    run_check "$variant unit t_modexp" \
      env -u ACCEL SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_modexp.pnk" "$PRE_DIR/modexp.in" @guest/test/exp_modexp.py
    run_check "$variant unit t_recover" \
      env -u ACCEL SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_recover.pnk" "$UNIT_INPUT" @guest/test/exp_recover.py
    run_check "$variant unit t_precompiles" \
      env -u ACCEL SPIKE_OUTPUT_LEN=65536 "$ROOT/tools/unit.py" \
      "$ROOT/guest/test/t_precompiles.pnk" "$PRE_DIR/precompiles.in" @guest/test/exp_precompiles.py
  fi
}

# t_globals has no data dependency, but unit.py still needs a framed input.
# The expected pointers use the fixed heap base from guest/runtime/start.S.
# The vector-backed unit tests use the same Python oracles for each build.
PRE_DIR="$ROOT/work/check-all/pre"
run_check "generate precompile vectors" \
  python3 "$ROOT/tools/gen_pre_vectors.py" "$PRE_DIR"
run_check "generate precompile wrapper vectors" \
  python3 "$ROOT/tools/gen_precompile_vectors.py" "$PRE_DIR/precompiles.in"

run_unit_variant software
run_unit_variant accelerated

# The aggregate M1 source is a compile smoke check.  Compile it in both modes
# so accelerator-only FFI symbols are checked even though it has no oracle.
run_check "compile t_m1_all software" \
  env -u ACCEL "$ROOT/guest/build.sh" "$ROOT/guest/test/t_m1_all.pnk" \
  "$LOG_DIR/t_m1_all-software.elf"
run_check "compile t_m1_all accelerated" \
  env ACCEL=1 "$ROOT/guest/build.sh" "$ROOT/guest/test/t_m1_all.pnk" \
  "$LOG_DIR/t_m1_all-accelerated.elf"

run_vector_variant() {
  local variant="$1"
  local script="$2"
  if [[ "$variant" == "accelerated" ]]; then
    run_check "vector $variant ${script%.sh}" \
      env ACCEL=1 "$ROOT/tools/$script"
  else
    run_check "vector $variant ${script%.sh}" \
      env -u ACCEL "$ROOT/tools/$script"
  fi
}

# These checkers build one test ELF themselves, so run each under both source
# configurations.  BLS and KZG already build and compare both variants in a
# single invocation and are therefore not duplicated here.
for script in check_u256.sh check_rlp.sh check_mpt.sh check_secp256k1.sh check_p256.sh; do
  run_vector_variant software "$script"
  run_vector_variant accelerated "$script"
done
run_check "vector check_bls12381 software/accelerated" \
  "$ROOT/tools/check_bls12381.sh"
run_check "vector check_bn254 software/accelerated" \
  "$ROOT/tools/check_bn254.sh" --only 1,2
run_check "vector check_kzg software/accelerated" \
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
  local variant="$1"
  local elf="$2"
  local manifest="$3"
  local out_dir="$4"
  local json="$5"
  local -a args=(--quiet-passes --out-dir "$out_dir")
  if [[ -n "${CHECK_ALL_EEST_JOBS:-}" ]]; then
    args+=(--jobs "$CHECK_ALL_EEST_JOBS")
  fi
  run_eest_with_baseline "$elf" "$manifest" "$json" "${args[@]}"
}

# Fixtures recorded as allowed failures in tools/eest-baseline.json for this
# manifest (e.g. software-only spike step-cap exits) are skipped: their
# software output is by definition not comparable with the accelerated one.
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
# work/inputs-rand/manifest.tsv when present, against both main guests.  The
# output-directory split is what makes the byte-for-byte differential check
# independent of the PASS/FAIL classification.
manifest_found=0
BASE_MANIFEST=""
BASE_ACCEL_DIR=""
for manifest in "$ROOT"/work/inputs*/manifest.tsv; do
  [[ -f "$manifest" ]] || continue
  manifest_found=1
  manifest_name="$(basename "$(dirname "$manifest")")"
  software_dir="$LOG_DIR/eest-${manifest_name}-software"
  accelerated_dir="$LOG_DIR/eest-${manifest_name}-accelerated"
  software_json="$LOG_DIR/eest-${manifest_name}-software.json"
  accelerated_json="$LOG_DIR/eest-${manifest_name}-accelerated.json"
  run_check "EEST $manifest_name software" \
    run_eest_variant software "$ROOT/guest/build/guest.elf" "$manifest" \
    "$software_dir" "$software_json"
  run_check "EEST $manifest_name accelerated" \
    run_eest_variant accelerated "$ROOT/guest/build/guest-accel.elf" "$manifest" \
    "$accelerated_dir" "$accelerated_json"
  run_check "EEST $manifest_name software/accelerated byte differential" \
    compare_eest_outputs "$manifest" "$software_dir" "$accelerated_dir"
  if [[ "$manifest_name" == "inputs" ]]; then
    BASE_MANIFEST="$manifest"
    BASE_ACCEL_DIR="$accelerated_dir"
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
    ZISK_DIR="$LOG_DIR/eest-inputs-accelerated-ziskemu"
    ZISK_JSON="$LOG_DIR/eest-inputs-accelerated-ziskemu.json"
    run_check "EEST inputs accelerated ziskemu" \
      run_eest_with_baseline "$ROOT/guest/build/guest-accel.elf" \
      "$BASE_MANIFEST" "$ZISK_JSON" --quiet-passes --ziskemu \
      --out-dir "$ZISK_DIR"
    run_check "EEST inputs Spike/ziskemu byte differential" \
      compare_eest_outputs "$BASE_MANIFEST" "$BASE_ACCEL_DIR" "$ZISK_DIR"
  else
    printf 'SKIP  EEST inputs accelerated ziskemu (set CHECK_ALL_ZISKE_PARITY=1)\n'
  fi
fi

printf '%s\n' '----------------------------------------'
printf 'Summary: %s PASS, %s FAIL\n' "$PASS_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
  exit 1
fi
