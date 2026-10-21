# Accelerators through CakeML's foreign-call interface

The accelerated guest (`ACCEL=1`) replaces software crypto with ZisK precompile CSRs,
reached through `@name(...)` foreign calls whose stubs are in `guest/runtime/start.S`.
This note records how those calls relate to the foreign-call interface that
CakeML/Pancake gives a callee, and how the guest and the stubs are arranged so that every
accelerator call fits it.

## The interface

`@name(c, n, a, m)` gives the callee the `n` configuration bytes at `c` and the `m`
array bytes at `a`. The callee returns new array bytes of the same length, and it
may change nothing else in the program's memory. Because the callee sees only those
bytes, the call is specified by a function of two byte lists, with no access to
memory, addresses or the rest of the machine. Flapjack models this path as
`panValueFfiExtCall` with an oracle `FfiOracle` (`FfiName → host → configuration →
bytes → FfiOracleResult`).

The ZisK CSRs do not have that shape by default. They take absolute pointers: a pointer
block whose entries lead to operands anywhere in memory, with results written elsewhere.
A call modelled on the hardware as it stands is a transformation of Pancake memory, which
flapjack describes as "an instruction-like target extension", not the ordinary
foreign-call boundary. The calls used to pass zero-length arrays
(`@arith256mod(p, 0, 0, 0)`), so as foreign calls they would have been specified as doing
nothing.

## The convention

An accelerator call fits the interface when everything the CSR reads and writes is in
the array, the configuration is empty, and the result is a function of the array bytes
alone. That needs the array to contain no addresses, and it is arranged on both sides:

* **Pancake side.** Each call's operands and results lie at fixed offsets in one block,
  and the call is `@name(blk, 0, blk, size)`. The array is exactly what the accelerator
  reads and writes.
* **Stub side.** The stub, which already sits between the compiled code and the CSR,
  builds the pointer block the CSR expects from the array pointer (`a2`): the operand
  addresses are the array address plus the fixed offsets. The block lives on the stub's
  own stack, outside the program's memory, and the stub touches only `t0`, `t1` and the
  stack below `sp`, so the argument registers are preserved. A CSR that takes the operand's
  own pointer (`keccakf`, point doubling) is called with `a2` directly.

So the array holds no addresses, the specification needs no base address, and there is no
obligation on the caller beyond passing an array of the right length. A call of any other
shape is a failed call. Passing an array costs nothing at run time, since only the formal
semantics reads it. On real hardware the stub spends a few extra instructions per call
building its pointer block.

## What is converted

All eighteen accelerators. The array layout of each call, in words, with the stub's
pointer block in the last column:

| call | array | pointer block the stub builds |
| --- | --- | --- |
| `@keccakf(p, 0, p, 200)` | the 25-word state | none: CSR 0x800 takes `a2` |
| `@sha256f(b, 0, b, 96)` | 4-word packed state, 8-word block | `{b, b + 32}` |
| `@arith256mod`, `@bn_arith256` (`b, 0, b, 160`) | `a, b, c, m, d`, 4 words each | five pointers, 32 bytes apart |
| `@bls_arith384` (`b, 0, b, 240`) | same, 6 words each; the modulus is copied in | five pointers, 48 bytes apart |
| `@secpadd`, `@bn_g1_add` (`b, 0, b, 128`), `@bls_g1_add` (`b, 0, b, 192`) | `p1, p2`: two points | `{b, b + 64}` (BLS: 96) |
| `@secpdbl`, `@bn_g1_dbl`, `@bls_g1_dbl` | the point, doubled in place | none: the CSR takes `a2` |
| `@bn_fp2_*` (`b, 0, b, 128`), `@bls_fp2_*` (`b, 0, b, 192`) | `f1, f2`: two elements | `{b, b + 64}` (BLS: 96) |
| `@blake2bround` (`b, 0, b, 264`) | the SIGMA row (a value), 16-word state, 16-word message | `{row, b + 8, b + 136}` |

`sha256_block` always builds the block at `sha_accel + 32`, copying it in unless the
caller already did (`sha256_pair` builds it there). For secp256k1 point addition the
caller's point is copied into the array and the sum copied back. The BN254, BLS12-381 and
BLAKE2b buffers, previously separate allocations, are now carved out of one block each.

The specifications are `Guest.acceleratorBytes` and its parts in `Guest/AccelFfi.lean`:
each takes the array, checks its length and an empty configuration, and returns the new
array. `Guest.guestOracle` installs them and answers `@halt` and `@trap` by returning
the array unchanged. `Guest/Accel.lean` keeps a transcription of ZisK's `csrsWrite` over
word memory as the reference the specifications are checked against.

A failing accelerator call (zero modulus, an unreduced or degenerate curve input, a
BLAKE2b row of 10 or more) ends the run in the model as a final FFI event,
`.final .failed`, which is what a trapping machine is, instead of an evaluation failure.

## What is checked

* `lake exe accel-ffi-check` (also in `tools/check_all.sh`): `keccakfBytes` gives the
  SHA3-256 digest of the empty message from its padding block, `sha256fBytes` gives
  SHA-256("abc") in the packed layout the guest uses, malformed shapes are rejected, and
  every other accelerator's specification agrees with the word-memory reference
  `acceleratorEffect` on concrete vectors, failures included. The reference follows
  pointers, so it is given the pointer block the stub builds. The vectors: arithmetic with
  4 and 6 limbs and a zero modulus, point addition and doubling on secp256k1, BN254 and
  BLS12-381 (generator, G + 2G, G + G, an invalid point), Fp2 operations with valid and
  out-of-range elements, and BLAKE2b rows 3, 9 and 12.
* The secp256k1, P-256, BN254, BLS12-381 and KZG vector checks and the `t_blake2f`,
  `t_precompiles`, `t_sha256` and `t_keccak` unit tests, accelerated, which exercise the
  converted calls through the new stubs under Spike.
* `tools/accel-ffi-smoke.py` (also in `check_all`): `guest/test/accel_ffi_smoke.pnk`
  makes one `@keccakf` and one `@sha256f` call, and its output on `ziskemu`, through the
  stubs and the real CSRs, equals the `hashlib` reference for the same inputs. This ties
  the byte-level specifications to the hardware behaviour for those vectors.
* `lake build Guest` (also in `check_all`, so the Lean library stays in step with the
  guest sources).
* The whole `tests-zkevm@v21.0.1` corpus on `ziskemu` with the accelerated guest:
  33,614 of 33,614. Counting real ZisK steps (the stubs' instructions are executed, though
  the formal model counts a foreign call as one step), mean steps over the passing cases
  went from 8,835,587 before the conversion to 8,935,499 (+1.1%), almost all of it the
  stubs building their pointer blocks, and the largest case from 12,276,776,458 to
  12,287,352,867 (+0.09%).

## How the calls are tested

Through compilation: the Pancake program is compiled and run, and the foreign calls are
exercised on the compiled code against `ziskemu`'s real accelerator CSRs. The Lean
semantics is not executed on programs for this. Running the guest in it was already
impractical, and a program that reads memory after a foreign call with a large array
does not finish at all, because flapjack's `panValueFfiWriteBytes` (a port of CakeML's
`write_bytearray`) takes time exponential in the array length. Symbolic proofs are not
affected.

When flapjack's compiler correctness theorem is available, the byte-level
specifications here are what it is instantiated with: each accelerator call is a foreign
call whose result is a function of its array bytes, and the stub satisfying that function
is the platform assumption. Until then the compiled-code tests above are the evidence.

## What it does not show

* Conformance of the stubs and ZisK to the specifications is an assumption about the
  platform, as CakeML's is about its C stubs. It is checked here only by tests, and for
  `keccakf` and `sha256f` against `hashlib`. A mistake in a stub's offsets would show as
  wrong results on hardware but not in the model, which is why the stubs and the Pancake
  layouts are listed side by side above.
* The Pancake memory model must cover the array: `read_bytearray` fails outside the
  program's addressable memory.
