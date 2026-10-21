# ZisK cost of this guest vs the reth and ethrex guests, on testnet blocks

This measures, under `ziskemu -X`, how many ZisK steps and how much estimated
cost it takes this repo's guest to validate a real testnet block, next to the
published reth and ethrex stateless-validator guests, on the same block. It
follows the comparison in
[issue #54](https://github.com/pirapira/stateless-pancaketh/issues/54) (there:
`glamsterdam-devnet-7` block `115260`, same block as
[ZISK-PROVE-BLOCK-FLAPJACK.md](ZISK-PROVE-BLOCK-FLAPJACK.md)), but every number
here is measured by the commands below rather than quoted from a gist.

"Cost" is the `TOTAL` line of `ziskemu -X`, ZisK's own cost estimate (the unit
its proving cost scales with). No proofs are generated, and no proving time is
measured.

## Summary

* On the ten devnet-7 blocks `115260`–`115269` (65–98M gas each), this guest
  (accelerated build) costs **7.1–9.0× (geometric mean 8.0×)** what the reth
  guest costs and **4.0–6.1× (4.9×)** what the ethrex guest costs. On block
  `115260`: 25.72G vs 3.15G (reth) vs 4.24G (ethrex); 263.4M steps vs 15.7M vs
  25.7M.
* On six current-spec stress blocks from `tests-zkevm@v21.0.1`, with every
  guest at its newest release, the ratios are 2.8–8.5× vs reth (mean 5.8×) and
  2.4–8.7× vs ethrex v28 (mean 4.3×).
* Breakdown for block `115260`: precompile cost is comparable across the
  three guests (1.80G here vs 1.27G reth vs 1.40G ethrex). The gap is in
  executed instructions: 17.9G of `MAIN` cost here vs 1.07G for reth. This
  document does not profile why.
* **The guest versions in the headline table are not the newest, on purpose.**
  No current guest (ours included) validates these devnet-7 blocks, because
  they were produced under older EVM rules. The table uses, for each
  implementation, the release that does validate them; see
  [Why the versions differ](#why-the-versions-differ).
* Every run's output was compared with the fixture's expected result, and all
  of them match (the software build, run on one block, matches too).

## Why the versions differ

The devnet-7 blocks carry a `statelessInputBytes`/`statelessOutputBytes` pair
from the `tests-zkevm` v0.6.x era (container `[new_payload_request, witness,
chain_config, public_keys]`, devnet-7 gas rules). Since then the stateless
schema and several gas rules have changed, and the guests moved with them:

| Implementation | Release | Targets |
| --- | --- | --- |
| this repo, before [#136](https://github.com/pirapira/stateless-pancaketh/pull/136) (`ca4f557`) | matched | `tests-zkevm@v0.6.2` |
| reth `f804dc1`, ethrex `v23.0.0` (`ere-guests` v0.16.0, 2026-08-21) | matched | v0.6.x layout, devnet-7-era rules |
| reth `0.1.0-rc.3`, ethrex `v27.0.0` (`ere-guests` v0.17.1, 2026-09-24), ethrex `v28.0.0` (2026-09-29) | current | `tests-zkevm@v0.8.x` layout (adds `chain_id`, keeps `public_keys`) |
| this repo, `main` since #136 | current | `tests-zkevm@v21.0.1` (drops `public_keys`) |

Re-wrapping the devnet-7 input for each current guest's layout is mechanical
(the nested encodings did not change), but every current guest then rejects
every block, because the rules differ: `successful_validation` is 0 for all
40 runs (10 blocks × 4 current guests) in the second table of
[Experiment A](#experiment-a-devnet-7-blocks-version-matched-guests). So
Experiment A uses version-matched guests, and Experiment B checks the current
versions against each other on blocks from the current spec's own fixtures.

No client guest speaks the v21.0.1 layout yet. For Experiment B, the clients'
v0.8.4-layout input is derived from each v21.0.1 fixture input by appending the
transactions' public keys, recovered in the driver from the signatures. All
current guests then return exactly the fixture's expected result on every
Experiment B block, so they agree with the spec on those blocks. The clients
get public keys as input while this guest recovers every sender in-guest, so
the ratios include that work on our side.

## Prerequisites

* Python 3, `curl`, a `tar` with zstd support (Ubuntu: `zstd`), `git`.
* The guest-build toolchain from README's "Toolchain" (`lake`/`elan`,
  `riscv64-unknown-elf-{as,ld}`), to build this repo's guest.
* About 6.5 GB of RAM per concurrent `ziskemu` job (the driver defaults to 6).
* No ZisK installation is needed: `tools/compare-clients.py fetch` downloads
  the v1.1.0-alpha emulator into `work/cmp/` and leaves `~/.zisk` alone.
  v1.1.0-alpha is the ZisK version the client guests were built for.

Everything is written under `work/cmp/` (gitignored). The driver checks the
SHA-256 of every download; the digests also match the ones GitHub publishes
for each release asset.

## Versions used

| Component | Version | SHA-256 of the file used |
| --- | --- | --- |
| `ziskemu` | 1.1.0-alpha (`9a5a1ac`), from `cargo_zisk_linux_amd64.tar.gz` | tarball `b6aebca0…7d17` |
| pancake guest, matched | `ca4f557`, flapjack `2732831e`, accelerated | `f97eaa8b…5260` |
| pancake guest, matched, software | same commit, default build | `758ff4c3…c372` |
| pancake guest, current | `b2b653b` (`tests-zkevm@v21.0.1`), accelerated | `11811710…a6a9` |
| reth guest, matched | `f804dc1`, `ere-guests` v0.16.0 | `194118a5…94cd` |
| ethrex guest, matched | v23.0.0, `ere-guests` v0.16.0 | `698d7bac…bd59` |
| reth guest, current | 0.1.0-rc.3, `ere-guests` v0.17.1 | `89e4d8d4…a922` |
| ethrex guest, current | v27.0.0, `ere-guests` v0.17.1 | `760f6404…bbcbad8` |
| ethrex guest, current | v28.0.0, lambdaclass/ethrex release | `5ba7fec4…9bef0` |
| devnet-7 batch | `115260-115269.tar.zst` | `30562c14…0405` |
| Host | Ubuntu 24.04, 32 cores | |

Measured on 2026-09-30. The two pancake ELFs are built locally, so their
digests should reproduce with the same commit, `flapjack` pin and
`riscv64-unknown-elf` toolchain; if they do not, the step counts below are the
thing to compare.

## Reproduce

Fetch the client guests and the emulator:

```bash
tools/compare-clients.py fetch
```

Build the version-matched pancake guests (the commit just before #136) in a
scratch worktree, reusing this checkout's Lean dependencies, and the current
guest:

```bash
git worktree add --detach work/cmp/pancake-old ca4f557
ln -s "$PWD/.lake" work/cmp/pancake-old/.lake
(cd work/cmp/pancake-old &&
  ACCEL=1 guest/build.sh guest/src/main.pnk build-accel.elf &&
  guest/build.sh guest/src/main.pnk build-soft.elf)
cp work/cmp/pancake-old/build-accel.elf work/cmp/elf/pancake-ca4f557-accel.elf
cp work/cmp/pancake-old/build-soft.elf  work/cmp/elf/pancake-ca4f557-soft.elf
unlink work/cmp/pancake-old/.lake && git worktree remove --force work/cmp/pancake-old

tools/build_both.sh                       # guest/build/guest-accel.elf, current
```

Experiment A, about 6 minutes:

```bash
tools/compare-clients.py devnet7 \
  --pancake-elf work/cmp/elf/pancake-ca4f557-accel.elf \
  --pancake-soft-elf work/cmp/elf/pancake-ca4f557-soft.elf \
  --current-pancake-elf guest/build/guest-accel.elf
```

Experiment B, about 15 minutes (one block runs 13.4 G steps in this guest):

```bash
tools/make-inputs.sh --all work/inputs-all        # converts tests-zkevm@v21.0.1
tools/compare-clients.py corpus --pancake-elf guest/build/guest-accel.elf \
  --match test_requests_exhaust_block_gas test_deposit_high_count \
          test_block_at_rlp_limit_with_logs
```

Both write a JSON file (`work/cmp/devnet7.json`, `work/cmp/corpus.json`) and
print the tables below; `tools/compare-clients.py table FILE.json` reprints
them. The driver exits with an error if a download's digest is wrong; a guest
whose output differs from the fixture's expected result is marked `✗` in the
table.

## Experiment A: devnet-7 blocks, version-matched guests

Block `115260` is the doc's block; `115261`–`115269` are the rest of the same
batch. Steps are ZisK steps; cost is `ziskemu -X` `TOTAL`, in units of 10⁹.
All 31 outputs (ten blocks × three guests, plus the software build on
`115260`) equal the fixture's expected 69-byte result.

| block | gas used | pancake steps | pancake cost | reth steps | reth cost | ethrex steps | ethrex cost | pancake / reth cost | pancake / ethrex cost |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 115260 | 65,318,413 | 263,371,236 | 25.72G | 15,674,595 | 3.15G | 25,697,994 | 4.24G | 8.2x | 6.1x |
| 115261 | 88,858,773 | 966,673,024 | 89.24G | 70,024,356 | 9.91G | 171,710,106 | 20.73G | 9.0x | 4.3x |
| 115262 | 72,583,260 | 741,830,864 | 68.43G | 59,312,977 | 8.61G | 108,822,504 | 13.76G | 8.0x | 5.0x |
| 115263 | 90,731,295 | 720,602,563 | 66.68G | 57,776,976 | 8.54G | 130,606,028 | 16.15G | 7.8x | 4.1x |
| 115264 | 79,059,591 | 550,148,985 | 51.86G | 42,254,365 | 6.71G | 81,726,975 | 10.90G | 7.7x | 4.8x |
| 115265 | 75,831,126 | 185,626,457 | 18.45G | 12,044,553 | 2.58G | 21,087,566 | 3.58G | 7.1x | 5.2x |
| 115266 | 97,658,620 | 1,242,679,410 | 113.88G | 94,391,597 | 12.98G | 211,885,509 | 25.24G | 8.8x | 4.5x |
| 115267 | 72,383,190 | 555,243,726 | 52.30G | 38,662,286 | 6.29G | 79,197,725 | 10.56G | 8.3x | 5.0x |
| 115268 | 69,031,551 | 278,893,940 | 27.81G | 14,637,588 | 3.70G | 22,157,780 | 4.53G | 7.5x | 6.1x |
| 115269 | 96,201,672 | 993,685,160 | 91.45G | 78,397,112 | 11.18G | 189,312,105 | 22.73G | 8.2x | 4.0x |

(pancake = accelerated build at `ca4f557`; reth = `f804dc1`; ethrex =
v23.0.0.) The step count for block `115260` (263,371,236) is the same number
[ZISK-PROVE-BLOCK-FLAPJACK.md](ZISK-PROVE-BLOCK-FLAPJACK.md) records for it.

The software (no accelerator) build of the same commit, run on block
`115260` only: 6,159,108,555 steps, 645.91G cost, 25× the accelerated build's
cost.

Cost breakdown for block `115260`:

| cost category | pancake | reth f804dc1 | ethrex v23.0.0 |
| --- | ---: | ---: | ---: |
| steps | 263,371,236 | 15,674,595 | 25,697,994 |
| MAIN | 17.91G (70%) | 1.07G (34%) | 1.75G (41%) |
| OPCODES | 3.57G (14%) | 0.17G (5%) | 0.31G (7%) |
| PRECOMPILES | 1.80G (7%) | 1.27G (40%) | 1.40G (33%) |
| MEMORY | 2.16G (8%) | 0.36G (11%) | 0.49G (12%) |
| BASE | 0.29G (1%) | 0.29G (9%) | 0.29G (7%) |
| **TOTAL** | 25.72G (100%) | 3.15G (100%) | 4.24G (100%) |

The current guests on the same ten blocks: all 40 runs return
`successful_validation = 0`, for the rules reason above.

| block | pancake@v21.0.1 | reth-0.1.0-rc.3 | ethrex-v27.0.0 | ethrex-v28.0.0 |
| ---: | :---: | :---: | :---: | :---: |
| 115260 – 115269 (every block) | succ=0 | succ=0 | succ=0 | succ=0 |

(The driver prints one row per block; they are identical.)

### Which ZisK version

The cost estimate is specific to the ZisK version. Block `115260` on the
ziskemu 1.3.0-alpha this repo's other documents use (`~/.zisk/bin/ziskemu`),
same ELFs and inputs:

| guest | steps | cost, 1.1.0-alpha | cost, 1.3.0-alpha |
| --- | ---: | ---: | ---: |
| pancake (`ca4f557`, accelerated) | 263,371,236 | 25.72G | 25.17G |
| reth `f804dc1` | 15,674,595 | 3.15G | 2.69G |
| ethrex v23.0.0 | 25,697,994 | 4.24G | 3.77G |

Steps are identical; the cost model differs, and the client guests get 11–15%
cheaper under 1.3.0-alpha against about 2% for this guest, so the cost ratio
on this block moves from 8.2× to 9.4× (reth) and from 6.1× to 6.7× (ethrex).
The tables above use 1.1.0-alpha throughout, the version the client guests
target.

## Experiment B: current versions on `tests-zkevm@v21.0.1` blocks

Every guest at its newest release. These are synthetic stress blocks from the
current fixtures, not testnet traffic: four blocks that fill the block gas
limit with system-contract requests, one 8.4 MB block at the RLP size limit
with logs, and one block with the maximum number of deposit requests. Every
output equals the fixture's expected 43-byte result.

| block (tests-zkevm@v21.0.1) | input | pancake steps | pancake cost | reth rc.3 steps | reth rc.3 cost | ethrex 27 steps | ethrex 27 cost | ethrex 28 steps | ethrex 28 cost | pancake / reth | pancake / ethrex 28 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `test_requests_exhaust_block_gas (BuilderDepositRequest)` | 63,409 B | 116,853,902 | 11.17G | 12,259,404 | 1.87G | 22,796,611 | 2.93G | 21,065,887 | 2.78G | 6.0x | 4.0x |
| `test_requests_exhaust_block_gas (BuilderExitRequest)` | 45,482 B | 210,149,787 | 19.30G | 22,396,506 | 2.84G | 35,633,978 | 4.17G | 33,437,690 | 3.97G | 6.8x | 4.9x |
| `test_requests_exhaust_block_gas (ConsolidationRequest)` | 50,074 B | 107,365,337 | 10.49G | 9,462,289 | 1.70G | 23,382,735 | 3.07G | 21,036,105 | 2.86G | 6.2x | 3.7x |
| `test_requests_exhaust_block_gas (WithdrawalRequest)` | 48,150 B | 122,153,240 | 11.83G | 10,200,664 | 1.79G | 24,078,070 | 3.16G | 21,879,844 | 2.97G | 6.6x | 4.0x |
| `test_block_at_rlp_limit_with_logs` | 8,394,657 B | 859,421,015 | 104.04G | 161,080,570 | 37.34G | 176,693,328 | 44.11G | 167,931,196 | 43.40G | 2.8x | 2.4x |
| `test_deposit_high_count` | 1,598,639 B | 13,364,108,009 | 1174.46G | 1,390,473,859 | 138.66G | 1,318,258,637 | 135.40G | 1,317,841,725 | 135.36G | 8.5x | 8.7x |

Across the six blocks the cost ratio vs reth rc.3 is 2.8–8.5× (geometric mean
5.8×), vs ethrex v27 2.4–8.7× (4.1×) and vs ethrex v28 2.4–8.7× (4.3×).

## Caveats

* **Different versions in Experiment A.** The matched guests are the ones that
  validate the devnet-7 blocks, not the newest of each; they are also not
  identical to the current ones in cost (reth and ethrex changed between
  releases). Experiment B is the same-version check; it is synthetic.
* **Estimates, not proving.** `TOTAL` is an emulator-side cost estimate, and
  its model changes between ZisK versions (see the table above). Wall-clock
  and proof-size comparisons would need `cargo-zisk prove` on each guest and
  are not done here.
* **Blocks are not a workload sample.** Ten consecutive devnet-7 blocks from
  a network running load generators, plus six stress tests. The ratios vary
  from 2.4× to 9× across these blocks.
* **Inputs are not identical in layout.** Clients read `public_keys` from the
  input; this guest recovers senders in-guest. Clients were built by their own
  projects' toolchains, this guest by `flapjack`; nothing here controls for
  that.
* **Outputs were checked, not proofs.** "Valid" means the guest's result bytes
  equal the fixture's `statelessOutputBytes`; it is not a check of the
  fixtures against an independent implementation.
* **No Sepolia/current-rules testnet block yet.** The current spec's first
  real testnet blocks do not exist: ethrex v28's release notes schedule
  Glamsterdam on Sepolia for 2026-10-06. The devnet-7 data in Experiment A
  comes from a network running older rules. After activation, the same
  measurement can be repeated on real blocks once a v21.0.1-layout input can
  be produced for them (the `witness-generator-spec-cli` in
  [eth-act/zkevm-benchmark-workload](https://github.com/eth-act/zkevm-benchmark-workload)
  is the tool that produced the devnet-7 data); this was not attempted.
* The `gist` numbers quoted in issue #54 (reth v0.1.0-rc.1: 124,579,543 steps,
  14.87G; evm-asm: 4,345,958,375 steps, 938.6G) are from ZisK 0.16.0 and are
  not reproduced here; the reth guest has changed a great deal since (15.7M
  steps on the same block now).
