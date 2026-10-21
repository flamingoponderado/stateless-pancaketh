# Reproduce the full EEST run with Spike

This is the complete `tests-zkevm` stateless-fixture run, not the small
`tools/check_all.sh` sample. `tools/eest-run.py` compares each guest result
with the fixture's `statelessOutputBytes` and reports root, success, and tail
regions. The command below uses the accelerated guest under Spike: `ACCEL=1`
selects the same precompile acceleration points that Spike implements, while
the runner itself remains Spike-only. No ziskemu is needed. The guest is
built with `flapjack` (`guest/build.sh`'s default `COMPILER`); pass
`COMPILER=cake` instead to use a bootstrapped/prebuilt CakeML `cake` binary.

## Prerequisites

Follow `README.md`'s "Quick start" section first: it covers cloning, the
`lake`/`elan`, `riscv64-unknown-elf-{as,ld}`, and Spike-build
(`libboost-all-dev`, `device-tree-compiler`, `libssl-dev`) prerequisites,
initializing the `evm-asm` and `riscv-isa-sim` submodules, and building
`spike_run`. This document only adds the full-corpus-specific steps below,
against the EEST fixture tag this repo currently pins
(`eest-fixture-tag.txt` at the repository root; `tests-zkevm@v21.0.1` for the
recorded run below).

## Fetch, convert, build, and run all fixtures

`tools/eest-spike-full.sh` fetches the pinned EEST fixture tag, converts the
whole corpus, builds the accelerated guest, and runs it under Spike:

```bash
tools/eest-spike-full.sh
```

Its output directory is named with the source commit
(`work/eest-spike-<commit>`) so result files can't be mistaken for a run
from another checkout; re-running it with the same commit checked out
reuses that directory's manifest. `SPIKE_RUN` and `EEST_JOBS` (default 32)
are overridable env vars; see the script for details.

`eest-run` exits zero only when every record passes, which is
`tools/eest-spike-full.sh`'s own exit code. A nonzero exit is useful: the
JSON and per-fixture logs remain under the commit-named run directory for
inspection and reruns with `--from-json` or `--labels`.

## Recorded result

Run on stateless-pancaketh commit
`fb4553b7ac75caba73f01e7e0f29056fc12c8195`, with 32 Spike workers and the
accelerated guest built with `flapjack` (5 min 36 s wall time), against
`tests-zkevm@v21.0.1` (both the `blockchain_tests` and
`blockchain_tests_engine` fixtures):

```text
records: 33614
PASS(full): 33605
PASS(malformed): 9
eest-run exit: 0
```

There were no fixture failures. The commit-qualified run directory and result
JSON are the reproducible record for this passing revision; the tracked
`tools/eest-baseline.json` is not used by this command.

The same accelerated guest (the same ELF: sha256
`1181171037da6360b54665ad0ff6840572d03d1ac69178076302599c3914a6a9`) was also
run over the same 33,614 inputs under `ziskemu 1.3.0-alpha`:

```bash
python3 tools/eest-run.py work/eest-spike-<commit>/guest-accel.elf \
  work/eest-spike-<commit>/inputs/manifest.tsv --ziskemu --quiet-passes
```

```text
total: 33614  PASS(full): 33605  PASS(malformed): 9
steps over passing cases: min=25748 max=13364108009
```

(58 min on 32 cores; the largest blocks run to ~13.4 billion steps.) That run
was made from the working tree before it was committed; the guest sources
were unchanged by the commit, which is why the ELF digests match.

The earlier recorded result for `tests-zkevm@v0.6.2` (commit `1489defb`, 26,104
records: 26,096 `PASS(full)` and 8 `PASS(malformed)`, built with `cake`) is
superseded by the above; the schema and several gas rules changed between the
two (see [issue #135](https://github.com/pirapira/stateless-pancaketh/issues/135)
for the list), so its numbers aren't comparable.
