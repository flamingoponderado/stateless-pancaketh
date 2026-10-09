# Goal 1 (issue #73): a source-level Pancake step bound for the guest

Status of the three `sorry`s of `Guest/StepBound.lean`:

| | state |
|---|---|
| `declaredBlockGasLimit` | **done** — `Guest/InputDecode.lean`, differentially validated against the guest |
| `guestPancakeStepBound` | open |
| `guest_terminates_within_step_bound` | open — was **false as stated**; [the obstruction](#the-obstruction) is fixed, the bound itself is what is left |
| *foundation* | [fuel monotonicity](#the-step-calculus-flapjackpanvalueffifuel) — upstreamed to `Flapjack/PanValueFfiFuel.lean`; without it no two cost lemmas compose |

Two guest bugs were found on the way, both of which made the theorem false as
stated and both now fixed: [`@trap` returning](#the-obstruction), and
[BLAKE2F's SIGMA row index](#a-second-evaluation-failure-path-blake2f-fixed) —
the latter a real halt on ordinary EIP-152 input, not only a modelling artefact.

## `declaredBlockGasLimit`

`Guest/InputDecode.lean` mirrors the guest's own decoder — `decode_stateless_input`,
`decode_payload`, `decode_requests`, `decode_bytes_list` and the helpers
`ssz_check_offsets`, `ssz_split_var_list`, `ssz_fixed_list_count`,
`ssz_optional_u64` of `guest/src/ssz.pnk`, with the field offsets and list
limits of `guest/src/types.h` — as a function of the input bytes. Every
`ssz_fail` site is a `none`, in the guest's order, so
`InputDecode.decodeStatelessInput` is `some` on exactly the inputs on which the
guest returns rather than raising `SszErr`. `declaredBlockGasLimit` is the
payload's `gas_limit` field, which `fork.pnk` copies to `HDR_GAS_LIMIT` and
then to `BE_GAS_LIMIT`.

The record it returns also carries the transaction slices, witness node/code/header
slices and the request counts — the sizes a parametric bound would be stated in
terms of — so it is not only the gas limit.

### Validation

`main` returns `1` from its `catch SszErr` block and `0` once
`decode_stateless_input` has returned, so the value the run returns is an exact
oracle for "this input decodes". `lake exe input-decode-check` compares the two
on a corpus that `tools/ssz-inputs.py` generates:

```bash
tools/ssz-inputs.py work/ssz-inputs --fuzz
lake exe input-decode-check work/ssz-inputs/*.bin
```

* 44 base cases — a minimal well-formed `StatelessInput`; variants with
  non-empty extra data, transactions, withdrawals, block access list, witness
  lists and a chain id; gas limits 1, 200M and 2^64−1; 24 single-byte
  mutations; 10 truncations. **31 decoded, 13 rejected, 0 mismatches.**
* `--fuzz` adds 290 cases: every SSZ offset field of two base inputs set to
  each of eight boundary values (0, ±1, +4, the body length, one past it,
  `0xffffffff`, half the length) — the bytes a hand-written mirror is most
  likely to disagree on. **0 mismatches** (334 inputs in all: 49 decoded, 285
  rejected; re-run for the `tests-zkevm@v21.0.1` three-field `StatelessInput`).

Since the model is quadratic in the store count, the corpus deliberately keeps
every list small; see the note at the end of this file.

## The obstruction

**Fixed** — by [option 1](#the-fix-taken) below, which is in the guest source
and in the committed ASTs. The section is kept because the mechanism explains
why `trap_with` ends in a `throw`, and because the two rejected options are
worth not re-deriving.

As stated before the fix, `guest_terminates_within_step_bound` was false for
every value of `guestPancakeStepBound`. The premises admit inputs on which
`runGuestStepped input fuel = none` for every `fuel`, so `TerminatesWithin`
failed — and it failed on evaluation failure, which the theorem is meant to
rule out.

### Mechanism

1. `@trap` returns in the model. (This paragraph was written when the memory handler
   `guestMemoryFfi` answered `halt` and `trap`; the guest's foreign calls now all go
   through `guestOracle`, which returns the array unchanged for them, so the run
   continues all the same.) On the machine
   `ffitrap` (`guest/runtime/start.S`) jumps to `cml_exit` and never returns.
   The `Guest/Model.lean` docstring used to call this a safe
   over-approximation. It is not, in two ways: for `TerminatesWithin` it turns
   a halting machine run into an evaluation failure (step 3), and even when the
   run does complete, continuing past the trap can take a *different* path and
   reach a different control outcome and output than the machine's halt — see
   the 19,456-byte row in the sweep below.
2. So `alloc` keeps allocating past the heap. `alloc`
   (`guest/src/lib/mem.pnk:28`) calls `trap_with(1)` when
   `q >+ HEAP_END` and then, because the trap returned, executes
   `heap_ptr = q` and hands out an address beyond `HEAP_END`.
3. Byte-granular accesses above `HEAP_END` are unmapped, and unmapped means
   `none`. `guestInitialMemory` maps `[SCRATCH_BASE, HEAP_END)` only. Word
   stores extend the map (`panValueMemoryAccessOfModel` is built with the
   default `domain := fun _ => true`), but `ld8`/`st8` go through
   `panModelReadByte`/`panModelStoreByte`, which read the containing word cell
   and fail when it is absent. The guest has 697 byte-access sites (560 `ld8`,
   137 `st8`); the error paths after a trap reach one, and the whole stepped run
   is then `none`.

### Reproduction

The relationship that matters is "`alloc` traps exactly at the end of the
mapped region", and that is preserved if the heap is made smaller: moving
`@base` up (`baseAddress := heapEnd - budget`) leaves `HEAP_END` and the mapped
region where they are, so it is the real configuration at a smaller heap size.
The guest's own init allocations high-water at 17,408 bytes; from there:

| heap | input | result |
|---|---|---|
| high-water + 512 B | 2,000 B | **`none`** — `alloc(2008)` in `input_blob` overruns |
| high-water + 4,096 B | 2,000 B | returns normally, 24,544 steps |
| high-water + 512 B | 0 B | returns normally, 19,778 steps |

So it is the allocation, not the input's content, that turns the run into an
evaluation failure.

Sweeping the heap budget in 1 KiB steps from the init high-water, on the
minimal well-formed input of `Guest.InputDecode`'s test set (658 bytes,
`declaredBlockGasLimit = some 200000000`), against the same guest with the
`throw TrapErr` of fix 1 below:

| heap | baseline | with `throw TrapErr` |
|---|---|---|
| 17,408 B | `none` | `raised TrapErr`, 18,169 steps |
| 18,432 B | `none` | `raised TrapErr`, 23,565 steps |
| 19,456 B | returns normally, **137,650** steps | `raised TrapErr`, 28,596 steps |
| 20,480 B … 40,960 B (21 budgets) | returns normally, 137,596 steps | identical, 137,596 steps |

Two things to read off it. The baseline has two evaluation failures and the
patched guest none. And at 19,456 bytes the baseline *completed* a run the
machine would have halted, by a path 54 steps longer than the untrapped
one — the over-approximation claim does not hold even for runs that finish.

### At the real configuration

The heap is `HEAP_END − HEAP_BASE` = 2,952,790,016 − 2,701,131,776 =
**251,658,240 bytes (240 MiB)**, and `maxInputBytes` is **1,073,741,808 bytes**
— 4.27× the whole heap. `input_blob` (`guest/src/lib/mem.pnk`) reads the
host's length word, rejects a length above `MAX_INPUT_LEN` (= `maxInputBytes`)
with trap code 8, and otherwise goes straight to `alloc(len + 8)`, so

> every input longer than 251,658,232 bytes traps in `input_blob`.

(The `MAX_INPUT_LEN` guard is about a length the host contract cannot back at
all, not about the heap: it keeps `len + 8` from wrapping into a small
allocation that `alloc` would accept, after which the copy loop would walk off
the input region. Lengths between the heap size and `maxInputBytes` still trap
in `alloc` with code 1, as above. `lake exe input-arena-check` exercises both
sides of the boundary.)

Smaller inputs do it too, through amplification. `main` calls
`htr_new_payload_request` unconditionally once the input decodes, and that
reaches `htr_bytes_list` on the `block_access_list`: `pack_bytes` allocates
≈L and `merkleize`'s buffer ≤2L, both live at once, on top of the L the input
copy already holds. So an input of order 60 MiB whose block access list is most
of its bulk exhausts the heap as well.

Such inputs decode. The only length-dependent guard on the
`block_access_list` is `len - o_bal >+ MAX_BLOCK_ACCESS_LIST_BYTES`, and
`MAX_BLOCK_ACCESS_LIST_BYTES` is 2^30; `MAX_BYTES_PER_TRANSACTION` is also
2^30 and `MAX_WITNESS_NODES × MAX_BYTES_PER_WITNESS_NODE` is 4 GiB. So a
minimal well-formed input padded through its block access list to 300 MiB
decodes, declares whatever `gas_limit` we put in it, and satisfies both
premises.

(The model cannot be run on such an input to show this end to end:
`guestHostMemory` indexes a `List UInt8` per byte, so `input_blob`'s copy loop
is quadratic in the input length. A 100 KB input already does not finish.)

### The fix taken

The guest is not at fault: on the machine, heap exhaustion is a clean
deterministic halt with `trap=1` in the debug bytes. What was wrong is that
`@trap` returns in the model. Making it terminal fixes the whole class at once
— all seven `trap_with` sites (`alloc`, `frame_mem_alloc`, `scratch_alloc`,
division by zero, base-fee overflow, and the two journal-full sites) become
immediate termination, which `TerminatesWithin` accepts, and the
"trap continues down the error paths" caveat in `Guest/Model.lean` goes away.

**Option 1, raise instead of returning**, is what is in the tree. `trap_with`
(`guest/src/lib/mem.pnk`) declares `exception TrapErr : 1;` and ends with
`throw TrapErr code;` in place of its `return 0;`. Nothing catches `TrapErr`,
so it propagates to the top and the run ends as `.raised`, which
`TerminatesWithin` accepts. It needs no flapjack change, and it is dead code on
the machine: `ffitrap` (`guest/runtime/start.S`) jumps to `cml_exit`, so the
`throw` is never reached there.

What was checked:

* **The cpp-expanded diff is exactly those two lines**, for both builds
  (`Guest/guest.pp.pnk`, `Guest/guest-software.pp.pnk`), and the parse
  regenerated from them (`Guest/Ast.lean`, `Guest/SoftwareAst.lean`) differs
  only in the new `Decl.exnDecl "TrapErr"` and in `trap_with`'s tail becoming
  `Prog.raise "TrapErr" (Exp.var VarKind.local "code")`. `lake build` re-checks
  the ASTs against the sources (`Guest/AstParse.lean`).
* **Trapping runs terminate, non-trapping runs are unchanged**, on the heap
  sweep above: every `none` becomes `raised TrapErr`, and all 21 budgets from
  20,480 B keep 137,596 steps to the step. The trap fires from inside `main`'s
  `try … catch SszErr` in the 19,456-byte case and is not swallowed by it.
  Empty input is still 19,778 steps and the minimal well-formed input still
  137,596 (867,017 on the software build), with byte-identical output.
* **`declaredBlockGasLimit` still agrees with the guest** — `lake exe
  input-decode-check` on the 431 `tools/ssz-inputs.py --fuzz` inputs, 0
  mismatches.
* **`cake` still compiles both builds.** `cake --pancake --target=riscv`
  (CakeML v3479) accepts `Guest/guest.pp.pnk` and
  `Guest/guest-software.pp.pnk`; this mattered because `main` catches only
  `SszErr`, so `TrapErr` leaves it uncaught. Not checked end to end: the ELF
  link and a `ziskemu`/`spike` run, which need a `riscv64-unknown-elf`
  toolchain. Since `TrapErr` is inserted ahead of every other exception
  declaration the compiler's exception tags all shift by one; nothing outside
  the compiled program reads a tag (the debug byte at `OUTPUT_ADDR + 70` is an
  exception *payload*), but a machine run is the check that would confirm it.

Regenerating the ASTs is `tools/gen-guest-ast.sh`. It now runs on macOS as
well: it picks `clang -E` there, spells `sed -i` portably, and drops blank
lines so that GNU `cpp` and `clang -E` produce byte-identical `.pp.pnk` (they
were verified to, on this change).

The two options not taken:

2. **Let the memory handler signal a final event** (flapjack). A
   `PanValueMemoryFfiHandler` returns `Option (locals × memory × ffi)`, and the
   `.extCall` case of `evalPanValueFfiProgSteps` consults it unconditionally
   and always continues as `.normal`, so with a memory handler installed there
   is no path to `.finalFfi` at all. Widening its result — or falling through
   to the oracle when it declines — is the architecturally right fix, but it is
   a change in a pinned dependency. Worth doing upstream regardless: option 1
   makes the *guest* terminate on trap, it does not make `@trap` terminal for
   any other program the model is pointed at.
3. **Sharpen the premise.** Not sufficient on its own: a heap-fit hypothesis on
   `input.length` would not cover exhaustion reached from inside the run
   (`frame_mem_alloc`, `scratch_alloc`, `htab_grow`), and it would give up on
   inputs that the machine handles correctly.

Option 1 also *helps* the bound: every resource-exhaustion path becomes
immediate termination rather than a continuation that has to be bounded.

## The step calculus (`Flapjack.PanValueFfiFuel`)

`TerminatesWithin` asks for *some* fuel at which the run returns. Proving that
compositionally — a cost lemma per function, combined along the call graph —
means combining sub-proofs carried at different fuels, and that needs **fuel
monotonicity**: a successful run is unchanged, same control result *and* same
step count, at any larger fuel.

Flapjack did not have it. `Flapjack/PanSteppedSemantics.lean` proves the
`_fst`/`_snd` projections relating the stepped evaluator to the unstepped one,
and nothing about varying the fuel. So the issue's remark that "the stepped
semantics is compositional (steps add up), so per-function cost lemmas compose"
was true of the *definition* — `.seq` returns `firstSteps + secondSteps + 1` —
but there was no theorem to compose with.

This started life here as `Guest/StepCalculus.lean` so the pinned revision did
not have to move, and is now upstream in `Flapjack/PanValueFfiFuel.lean`
(flapjack #662) and `Flapjack/PanValueFfiClockFuel.lean` (flapjack #661), both
`sorry`-free. The local copy is deleted and the pin bumped; flapjack #659 is
what this closes.

* `Flapjack.StepCalculus.progMono`, `callMono` — for the mutually recursive
  `evalPanValueFfiProgSteps` / `evalPanValueFfiCallSteps`, by the
  functional-induction principle `evalPanValueFfiProgSteps.induct` (25 cases;
  18 are the constructors whose body does not mention fuel and close by
  unfolding both sides, 7 recurse: the call evaluator's successor case, `dec`,
  `seq`, `ite`, `call`, `decCall`, `while`).
* `evalPanValueFfiProgramStepped_fuel_mono` — the public entry point, which is
  what `Guest.runGuestStepped` is.
* In `Guest/StepBound.lean`: `runGuestStepped_fuel_mono` and
  `TerminatesWithin.mono` (bound weakening, so a parametric bound can be
  specialised to the constant).

Worth knowing when reading the evaluator: **fuel is a depth budget, not a work
budget.** `.seq first second` at `fuel + 1` evaluates *both* halves at `fuel`,
and `.while`'s next iteration also recurses at `fuel`, so fuel bounds syntactic
nesting and call depth as well as iteration count. Monotonicity is what makes
that workable — a bound proved for a sub-program stays true in a larger context.

### What the re-pin changed underneath

592 flapjack commits, and only three things reached the termination calculus —
worth recording, because each is a *tightening* of the model rather than a
refactor:

1. **A callee's parameters are now checked against its contract.**
   `evalPanValueFfiCallSteps` gates `bindPanValueParameters` behind
   `panValueParametersValid`, so every call rule carries that as a hypothesis
   (`hparams`), in the same style as the return-validity one it already had.
2. **A body that does not leave the callee is stuck.** `.normal`, `.broke` and
   `.continued` coming out of a function body are now `none`, where `.normal`
   used to be passed through. A Pancake body has to `return`, `raise`, or end
   in a final FFI event. `BodyEscapes` (`Guest/Termination.lean`) names the
   three outcomes a call can consume, and `callSteps_terminates` takes it as a
   hypothesis instead of claiming a result for all six.
3. **Comparison is a class now.** `PanCmp` replaced the bare `LT`/`DecidableRel`
   pair at the point of use, and RiscV words have their own instance —
   `lower` unsigned, `less` *signed*. The generic `panCmpOfLt` fallback makes
   both signed, so a module stating rules over an abstract `α` has to carry
   `[PanCmp α]` or it silently instantiates to the wrong comparison at `Word`.

Nothing else in the guest needed a change, which is a reasonable signal that
the `_runs` layer is stated against the semantics rather than against its
implementation.

## A second evaluation-failure path: BLAKE2F (fixed)

Fixing `@trap` (#76) removed one way for the model to be `none` where the
machine halts. Auditing the *other* handler that can decline — the accelerator
— turned up a second, and it is a real guest bug rather than a modelling
artefact.

The memory handler `guestMemoryFfi` (since removed: every accelerator is now a foreign
call specified by `Guest.acceleratorBytes`, and a failing call ends the run as a final
FFI event, `.final .failed`, instead of an evaluation failure) answered an accelerator
call with `none`
"for an unknown name or an input the machine model would trap on", and the
`.extCall` case of `evalPanValueFfiProgSteps` propagates that as `none` for the
whole run — evaluation failure at every fuel, exactly the class the trap fix
removed.

The reachable case is `@blake2bround`. ZisK's CSR 0x819 takes a **SIGMA row**,
not a round number: `csrsValid` requires `sigmaIdx < 10`
(`RiscvZkvm/Rv64/ZiskAccel.lean`) and the machine traps when it fails. The
guest's accelerated loop passed the raw round counter:

```
var r = 0;
while r <+ rounds {
  st b2_round, r;              /* r, not r % 10 */
  @blake2bround(b2_round, 0, 0, 0);
  r = r + 1;
}
```

while the software path immediately below it maintains a `row` that wraps at
10. `rounds` is user input — `pre_blake2f` reads it as `LD_BE32(data)` and
charges 1 gas per round — and **BLAKE2b's standard compression is 12 rounds**,
so an ordinary EIP-152 call reaches row 10 and traps.

Measured on the guest's own `blake2b_f`, driven at each round count (all-zero
state and message):

| rounds | accelerated, before | software | after the fix |
|---|---|---|---|
| 1, 9, 10 | digests agree with software | — | unchanged |
| 11, 12, 13, 21 | **`none`, every fuel** | correct digest | digests agree |

All seven digests match an independent Python BLAKE2b-F reference, so the
software build was always right and the accelerated one is now right too.

The fix mirrors the software path: keep a `row` counter that wraps at 10. It
touches only the `ZISK_ACCEL` branch, so `Guest/guest-software.pp.pnk` is
unchanged.

Consequences worth separating:

* **For the guest.** The accelerated build halted on any block containing a
  BLAKE2F call with `rounds >= 11`, which is the normal use of the precompile.
  That is a bug in the deployed build, independent of any proof.
* **For the theorem.** It was a second way for
  `guest_terminates_within_step_bound` to be false as stated, on inputs well
  inside the premises: 12 rounds costs 12 gas against a 200M limit, and the
  block is small.

### The rest of the accelerator surface

The other conditions under which `acceleratorEffect` declines were checked
against every call site in `guest/src`, and all are guarded by the guest:

| accelerator | declines when | guard |
|---|---|---|
| `secpadd`, `bn_g1_add`, `bls_g1_add` | `x1 == x2`, or a coordinate not reduced | `ec_add`/`ecp_add`/`g1_add` test `x1 == x2` first and route to doubling or to infinity |
| `secpdbl`, `bn_g1_dbl`, `bls_g1_dbl` | `y == 0`, or not reduced | `ec_double`/`ecp_double`/`g1_double` test `y == 0` and return infinity |
| `arith256mod`, `bn_arith256`, `bls_arith384` | modulus zero | the modulus is a constant written at init (`SECP_P`, `SECP_N`, the BN254/BLS field primes), never user data |
| `bn_fp2_*`, `bls_fp2_*` | an operand not reduced | operands are Montgomery-form field elements, reduced by construction |

So BLAKE2F was the only unguarded one.

## Structural termination rules (`Guest/Termination.lean`)

With monotonicity in hand, the next layer is a termination calculus, so a
whole-program proof can be assembled from per-construct facts. All `sorry`-free:

* **`while_terminates_inv`** — a loop terminates when an invariant `I` holds on
  entry and is preserved, the condition evaluates on every state satisfying
  `I`, and the body — whenever entered — terminates and strictly decreases a
  measure `μ`. Proved by strong induction on `μ`, taking `max` of the body's
  fuel and the tail's and lifting both with `progMono` — precisely the step
  that was impossible before. `while_terminates` is this with `I := True`.
* `seq_terminates`, `ite_terminates`, `dec_terminates`, `call_terminates` — the
  compositional rules for a function body.
* `callSteps_terminates` — the call evaluator itself. Its extra hypotheses are
  the evaluator's own `none` branches: the return- and exception-validity
  checks, the destination assignment, and a matching handler's termination.

The leaf constructors need no rule: `Terminates` for them is discharged at the
point of use by exhibiting the one-step run, and their only content is whether
their expressions evaluate.

* `while_terminates_of_increasing_counter` — the shape ~200 of the 257 loops
  actually have (`i <+ n`, `i < cap`, `i < 8`, ...): a counter the body strictly
  increases, against a bound. It does the truncated-subtraction argument once
  rather than per loop, and does not require the counter to stay under the
  bound, since overshooting sends the measure to zero, which is still a
  decrease.

Since the call graph is acyclic (#71), **what is left is invariants and
measures**: every remaining loop reduces to exhibiting a pair, and for most of
them that is a counter and a bound.

### Two things learned by pointing the rules at real guest code

Both came out of trying to prove an actual function rather than designing the
rules in the abstract, and both change how the remaining work has to be
organised.

**The invariant is not decoration.** A loop condition mentioning a local can
only be shown to evaluate on states where that local is bound, so an
invariant-free rule is unusable on anything real. `rlp_be_len` — four lines,
one loop — already needs one.

**Counters wrap, so per-loop lemmas are not independent.** The guest's counters
are `BitVec 64` and Pancake's `+` wraps, so "the body increases the counter" is
a real obligation:

| loop | diverges when | why |
|---|---|---|
| `memzero`'s `while i + 32 <=+ n` | `n ≥ 2^64 − 32` | `i + 32` wraps to `0`, the condition still holds, the counter restarts |
| `ceil_log2`'s `while (1 << d) <+ n` | `n > 2^63` | at `d = 64` the shift gives `0`, which is `<+ n` forever |

Neither is reachable — `memzero`'s call sites pass small constants, and
`ceil_log2` is only called from `merkleize` with SSZ chunk counts bounded by
the list limits — but **both are preconditions that only the caller can
discharge**. So the loops cannot be proved in isolation and then assembled;
each needs its bound threaded down from its callers. That is a structural
constraint on the remaining work, not a detail.

The counter corollary takes `counter` as a `ℕ` precisely so that this obligation
cannot be skipped.

## First guest function proved to terminate (`Guest/FunctionTermination.lean`)

`charge_gas_terminates`, `sorry`-free, composed from `dec_terminates`,
`ite_terminates` and `seq_terminates` against the AST as committed
(`chargeGasBody` is `Guest.guestFn_charge_gas`'s body, checked by `rfl`).

`charge_gas` was chosen because it has no loop, so it tests the calculus on
`dec`/`ite`/`seq`/leaves without needing a measure. Two things it showed:

* the leaf rules really are one-liners at the use site — `skip` closes by
  `rw [evalPanValueFfiProgSteps]` alone — so not writing lemmas for them was
  the right call;
* **`raise` is not free.** `Prog.raise` evaluates its payload and then requires
  `panValueExceptionValid` and `panValuePayloadWithinLimit` against the
  program's contracts, returning `none` otherwise. So every `throw` in the
  guest carries an obligation that the exception is declared with a matching
  shape — true here (`exception EvmErr : 1`), but it must be supplied, at every
  raise site.

Its remaining hypotheses are deliberate, and they named the next piece of
missing infrastructure: `Exp.load` and `Prog.store` bottom out in
`panValueFlatLoad` and `panValueStoreWithAccess`, about which flapjack proves
nothing.

### The memory layer (`Guest/Memory.lean`)

That piece now exists for word accesses, which is what `lds 1` and `st` compile
to everywhere in the guest:

* `panValueFlatLoad_one`, `panValueStoreWithAccess_word` — generic: a
  `Shape.one` load is exactly one underlying word read, a `.word` store exactly
  one underlying word write.
* `guest_readWord`, `guest_storeWord`, `guest_store_word_total` — the same
  under `Guest.guestMemoryAccess`.

The asymmetry in the last is worth stating plainly, because it is the one that
bit before: **a word store always succeeds.** The guest's access model is
`panValueMemoryAccessOfModel` with the default `domain := fun _ => true`, so
`st` *extends* the map rather than failing outside it, while `ld8`/`st8` go
through the model and fail on an absent cell. That asymmetry is exactly why
heap exhaustion became an evaluation failure rather than a clean stop before
the trap fix.

### The expression layer (`Guest/Expressions.lean`)

* `eval_const`, `eval_var_global`, `eval_var_local` — the leaves.
* `eval_global_add_const` — `base + K` where `base` is a global holding a word.
  This is the guest's pervasive address form (`ev + 64`, `msg + 136`, …) and it
  *always* succeeds: `RiscV.panRiscVWordOp .add` is total.
* `eval_load_global_add` and its counted form — `lds 1 (base + K)`, the guest's
  pervasive field read, combining this layer with the memory one.
* `eval_op2` — any two-argument operator, composing with arbitrary
  sub-expressions, with `wordOp_add`/`wordOp_sub` discharging its side
  condition. This subsumes the address form and is what the guest's value
  expressions need (`gl - amount`, `lds 1 (ev + 184) + amount`).
* `eval_cmp_locals` — a comparison of two word locals. Always succeeds:
  `RiscV.panRiscVCmp` is total, so the only way a guest comparison fails to
  evaluate is an unbound or non-word operand.
* `store_terminates` — **a word store terminates as soon as its two expressions
  evaluate**, with no further obligation, because the access model's `domain`
  is `fun _ => true`. Contrast the byte accesses, which can fail.

None of these hold by `rfl`: `evalPanValueExp` is defined by well-founded
recursion, so they go through the equation lemmas, and the list case is the
nested `evalPanValueExp.evalPanValueExps` rather than the top-level name.

### What that buys, concretely

`charge_gas_terminates_of_state` now needs, in place of the assumed gas load
and shape, only that the global `ev` holds a word and memory holds a word at
`ev + 64`. Two of its four obligations are discharged. `charge_gas_tail_terminates` then proves the whole tail — both stores and the
`return` — from state alone, chaining the two stores through the memory the
first one produces. Its `hne` hypothesis (the two field addresses differ) is
the kind of side condition that only appears once statements are composed for
real.

`Prog.return` and `Prog.raise` got named rules after all
(`return_terminates`, `raise_terminates`): an earlier claim here that the leaf
constructors need no rules was too strong. Those two check their payload
against the program's contracts and answer `none` otherwise, so a proof about
*any* guest function carries them — the control-flow analogue of the
no-wraparound conditions the loop measures need.

### `Terminates` does not compose; the rules need equational forms

`seq_terminates` takes the first statement's result `r1` as a parameter, and
rightly so: the second statement runs from whatever state the first left. But
that means the caller must supply an **equation**, `eval fuel₁ … = some (r1,
s1)`, not merely `∃ r, … = some r`. So each rule needs an equational twin, and
`Guest/Termination.lean` now has them: `skip_runs`, `ite_runs`,
`seq_runs_normal`, `seq_runs_raised`, `raise_runs`, `return_runs`, alongside
`store_runs` in `Guest/Expressions.lean`. They are the same proofs as the
`_terminates` rules, stated to say *what* the result is; every one of those
proofs already constructed it.

### The first guest function proved to terminate from state alone

`charge_gas_terminates_from_state` needs **no hypothesis about the evaluator**.
It suffices that:

* the global `ev` holds a word;
* memory holds words at the two fields `charge_gas` touches, `ev + 64` and
  `ev + 184`;
* `amount` is bound to a word;
* those two addresses differ;
* the program declares `EvmErr` with a matching shape and admits the payloads.

Both branches are proved: out of gas, where the `ite` raises and the tail never
runs, and the normal path, where the `ite` falls through with the state
unchanged and the tail does its two stores and the `return`.

That last group of hypotheses is not incidental, and it is the shape every
guest function will have. `Prog.raise` and `Prog.return` check their payload
against the program's contracts and answer `none` otherwise, so a termination
proof about any guest function carries them — the control-flow analogue of the
no-wraparound conditions the loop measures need.

### Termination is not a measure step: `charge_gas` semantically (`Guest/Gas.lean`)

`run_frames`'s measure is the gas left, so proving `charge_gas` *terminates*
buys nothing towards it. What the loop needs is that a charge **moves the
measure**, and that is an equation about the state `charge_gas` leaves, not an
existential that it left one.

`charge_gas_runs_normal` is that equation. On the branch the charge fits, and
under exactly the hypotheses of `charge_gas_terminates_from_state`,
`chargeGasBody` runs at fuel 5 to

    .returned _ g (chargeGasMemory m ev gl amount used) f [word 0]

where `chargeGasMemory` puts `gl - amount` at `ev + 64` and `used + amount` at
`ev + 184`. `charge_gas_decreases_gas` then reads the measure off it: the new
value at `ev + 64` is `gl - amount`, and

    amount <= gl  and  1 <= amount   implies   (gl - amount).toNat < gl.toNat

Proving that needed one new statement rule, `dec_runs` — the equational twin of
`dec_terminates`, restoring the shadowed local on the way out — completing the
`_runs` layer for everything `charge_gas` uses.

#### The wrap-around condition is the branch condition

The gas counters are `BitVec 64` and the guest charges with `-`, which wraps:
`0 - 1` is `2^64 - 1`, and an unguarded charge would move the measure **up**.
So `gas_strictly_decreases` is conditional on `amount <= gl` unsigned.

The pleasant part is that this is not an extra assumption to discharge
elsewhere. It is *the same fact* as the guest's own `gl <+ amount` test falling
through, because `Cmp.lower` is unsigned `<`:

    cmp_lower_false_of_le : b.toNat <= a.toNat -> (panRiscVCmp .lower a b != 0) = false

The guest checks for the borrow before it subtracts, and that check is what
licenses the measure. `Guest/Gas.lean` keeps these three facts apart from the
evaluator on purpose: the wrap-around hypothesis is the interesting half of
every gas argument and should be legible, not buried inside a proof about
`Prog.store`.

#### The second counter, and a finding: the gas sum is not monotone

Gas lives in two places, so no measure can be read off `EV_GAS_LEFT` alone.
`charge_state_gas` (`guest/src/evm.pnk:249`) draws from `EV_STATE_GAS_LEFT` and
spills into `EV_GAS_LEFT` only when the reservoir is short. Both of its paying
paths take the **sum** down by exactly the amount charged, and both are proved
in `Guest/Gas.lean` with the guest's own branch condition as the hypothesis:

    state_gas_sum_decreases_reservoir   sgl >=+ amount
    state_gas_sum_decreases_spill       sgl <+ amount, add_sat(sgl,gl) >=+ amount

Saturation in `add_sat` is harmless — a saturated `add_sat` is `2^64 - 1`,
which dominates any `amount` — and it is also what rules out a borrow in
`gl - rem`.

**But the sum still is not a measure.** `credit_state_gas_refund`
(`guest/src/evm.pnk:268`) *increases* `EV_GAS_LEFT + EV_STATE_GAS_LEFT` by its
whole argument, whatever `EV_STATE_GAS_SPILLED` holds — it adds
`min(amount, spilled)` to one counter and the rest to the other.
`credit_state_gas_refund_increases_sum` states that, machine-checked, so the
obstruction cannot be forgotten.

It is not a small increase. There are six call sites, crediting
`SG_STORAGE_SET` (97,920) or `SG_NEW_ACCOUNT` (183,600):

| site | credit |
|---|---|
| `op_sstore` (`evm.pnk:1242`) | `SG_STORAGE_SET` = 97,920 |
| `evm_calls.pnk:639`, `:653`, `:1023`, `:1103`, `:1209` | `SG_NEW_ACCOUNT` = 183,600 |

And on `op_sstore`'s credit path the *charge* is small. The credit fires when
`current != new_value`, `original == new_value` and `original` is zero — so
`oc` (original == current) is false, the `+ G_STORAGE_WRITE` branch does not
fire, and `gas_cost` is just `access_cost`, 100 warm or 3,000 cold. One SSTORE
can therefore move the gas sum **up by ~95,000**.

The repair is a conservation invariant:

    total state gas credited so far <= total state gas charged so far

which makes the reservoir bounded above by its initial value and restores a
measure. The five `SG_NEW_ACCOUNT` sites and the one `SG_STORAGE_SET` site
turn out to need quite different arguments.

##### The five `SG_NEW_ACCOUNT` credits are conserved *structurally*

Every one of them is guarded by a flag:

```
if new_account_charged != 0 {
  credit_state_gas_refund(SG_NEW_ACCOUNT);
}
```

and `new_account_charged` is set in exactly two places (`evm_calls.pnk:1012`
and `:1188`), both of the form

```
new_account_charged = 1;
charge_state_gas(SG_NEW_ACCOUNT);
```

— assignment and charge in the same block, nothing between them. Across the
frame boundary the flag is threaded explicitly: `start_child` takes it as a
parameter and stores it at `CK_NEW_ACCOUNT` in the continuation record
(`:749`), and the unwind path reads it back (`:610`) before the two credits at
`:638` and `:652`.

So the invariant here is not a subtle argument about state history; it is a
boolean that is only ever true when the charge happened. That is a proof
obligation about a flag, which is the easy kind.

##### `op_sstore`'s credit is *not* flag-guarded

It is guarded by a state condition — `cn == 0 && on != 0 && oz != 0` — so
conservation there rests on storage history: the credit needs `original == 0`
and `current != 0`, which within one transaction requires a prior SSTORE that
took the slot `0 -> nonzero`, and that one charges `state_gas =
SG_STORAGE_SET` (its guard `oc && !cn && oz` holds exactly there).

**That remains a source reading, not a theorem**, and it is the same class of
claim as issue #73's own gas sketch, which the census showed was wrong. It is
the one place where the conservation invariant genuinely has to be earned, and
nothing should be built on it until it is.

##### A third finding: gas is *moved*, not only spent

The same reading turned up something the measure has to respect independently.
Gas is reserved for a child frame and restored if the child does not start —
`generic_call`'s depth-limit path (`:1102`) and the insufficient-balance path
(`:1208`) both do

```
st ev + EV_GAS_LEFT, (lds 1 (ev + EV_GAS_LEFT)) + gas;
st ev + EV_STATE_GAS_LEFT, (lds 1 (ev + EV_STATE_GAS_LEFT)) + reservoir;
```

and `op_create` splits `gl - (gl >>> 6)` off for the child (`:1017`). These are
save/restore pairs, net zero — but only when both frames are counted. **The
measure must therefore be the sum over all live frames**, not the current
frame's two counters. A measure read off `ev` alone goes *up* the moment a
child frame declines to start.

#### `charge_state_gas`, reservoir path

`charge_state_gas` draws from `EV_STATE_GAS_LEFT` first, so the reservoir path
is the one that runs whenever the frame has state gas to spend — and it is
self-contained: it `return`s before reaching `add_sat`, so it needs no call
rule. `charge_state_gas_runs_reservoir` gives its equation at fuel 6 and
`charge_state_gas_decreases_sum_reservoir` reads the measure off the resulting
memory: the reservoir is down by `amount`, `EV_GAS_LEFT` is untouched, so the
sum falls.

It needed one new rule. The reservoir branch `return`s from *inside* a `seq` —
the `add_sat` half of the body is still syntactically ahead of it — so
`seq_runs_returned` had to join `seq_runs_raised`. The test is
`Cmp.notLower`, the mirror of `charge_gas`'s, and
`cmp_notLower_true_of_le` is the same observation once more: the guest
branches on the borrow before it subtracts.

#### Both charge functions are now total on what the measure needs

The census claim is "every opcode handler charges at least one gas **or ends
its frame**". For the two charge functions themselves, both halves are now
proved, and between them they cover every reachable path:

| path | outcome |
|---|---|
| `charge_gas`, fits | `charge_gas_runs_normal` → `charge_gas_decreases_gas` |
| `charge_gas`, short | `charge_gas_runs_raised` → frame ends |
| `charge_state_gas`, reservoir covers | `..._runs_reservoir` → `..._decreases_sum_reservoir` |
| `charge_state_gas`, spill covers | `..._runs_spill` → `..._decreases_sum_spill` |
| `charge_state_gas`, neither covers | `charge_state_gas_runs_raised` → frame ends |

Nothing inside either function catches `EvmErr`, so a raise leaves the
function and the frame is over: the caller gets a `.raised`, not a state it
can carry on from. That is what makes "or ends its frame" a genuine
alternative for the measure rather than a hole in it — the run does not go on
to execute another opcode from a gas counter that did not move.

#### `charge_state_gas`, spill path — the measure step is complete

When the reservoir is short, `charge_state_gas` asks `add_sat` whether the two
counters *together* cover the charge, empties the reservoir, and takes the
remainder out of `EV_GAS_LEFT`. `charge_state_gas_runs_spill` is that path end
to end from the committed AST, at fuel 11, and
`charge_state_gas_decreases_sum_spill` reads the measure off it.

**Both paying paths of both counters now move the measure down**, which is the
whole of the "charges >= 1 gas" half of the census claim:

| | equation | measure |
|---|---|---|
| `charge_gas` | `charge_gas_runs_normal` | `charge_gas_decreases_gas` |
| `charge_state_gas`, reservoir | `charge_state_gas_runs_reservoir` | `..._decreases_sum_reservoir` |
| `charge_state_gas`, spill | `charge_state_gas_runs_spill` | `..._decreases_sum_spill` |

The link on the spill path is `addSatOf_le_sum`: the guest's `tot >=+ amount`
test bounds `amount` by the *saturating* sum, and that bounds it by the true
sum — which is exactly the no-borrow condition `state_gas_sum_decreases_spill`
wants. So for a third time the guest's own branch is what licenses the
measure; there is still no place where a no-wraparound side condition had to
be assumed rather than read off a test the guest already performs.

This is also the first path in the guest that leaves its own function and
comes back, so it is where `decCall_runs` and `callSteps_runs_returned_none`
get used for real. The three stores are straight-line, except that the last
one *reads* `EV_STATE_GAS_SPILLED` after the first two have run — which is the
only reason disjointness hypotheses appear, and why they are only about
`ev + 192`.

#### `add_sat`, the first callee

`charge_state_gas`'s spill path calls `add_sat`, so it is the first guest
function proved as a *callee* rather than entered at the top.
`add_sat_runs` covers both paths — a carry, where the `ite` returns
`WORD_MAX` from inside the `seq`, and no carry, where it falls through to
`return s`.

Its statement has to say the callee left the heap alone (`m` and `f`
unchanged), because `decCall` runs its body in the *callee's* memory and FFI
state, not the caller's.

Two call rules were missing and are now in `Guest/Termination.lean`:

* `callSteps_runs_returned_none` — `Prog.decCall` calls with `info = none`, so
  `callSteps_runs_returned`, which needs a destination to assign to, does not
  apply to it;
* `decCall_runs` — the guest's `var x = f(...)` form.

The arithmetic is in `Guest/Gas.lean`. `add_sat_saturates` is the fact the
guest's overflow test actually relies on: **a sum coming out below one of its
own summands is precisely an unsigned carry**, so `s <+ a` detects exactly
`2^64 <= a + b`. `add_sat_ge` is the property `charge_state_gas` needs
downstream — the result dominates the true sum, capped at the word size —
which is what makes `tot >=+ amount` enough to rule out a borrow in
`gl - rem`.

#### Calls compose now

`callSteps_runs_returned` and `call_runs` (`Guest/Termination.lean`) complete
the `_runs` layer for the one construct that was still existential-only.
`callSteps_terminates` covers every control result and hands back an `∃`; a
caller that wants to keep going has to *know* the state it resumes in, so the
equational form is restricted to the case the guest actually uses — a callee
that `return`s, with a destination to assign to.

Worth noting which parts of the state survive a call, since it is not
symmetric: the callee's memory and FFI state are kept (the guest's heap is
global), the caller's locals come back from `assignPanValueCallResult` rather
than the callee's, and the globals are the callee's as amended by that
assignment.

#### The credit path, and the half of it that is conserved

`credit_state_gas_refund_runs` is the other side of `charge_state_gas`, and
the first function proved that moves the measure *up*. It is `min`'s only
caller, so `min` joins `add_sat` as a proved callee: `min_runs` is the
simplest guest function yet — no `dec`, just the comparison and two returns,
with the `ite`'s `then` branch returning out of the enclosing `seq`.

What the function leaves behind is `creditStateGasMemory`: `min(amount,
spilled)` goes back to `EV_GAS_LEFT` and comes off `EV_STATE_GAS_SPILLED`,
and the remaining `amount - min(amount, spilled)` goes to the reservoir at
`EV_STATE_GAS_LEFT`. As with the spill path the last store *reads* a counter
the first two have already written past, so two disjointness hypotheses
appear — and again only for the addresses that are actually re-read.

Reading the measure off that state splits the credit cleanly in two:

* `credit_state_gas_refund_conserves_spill` — the part routed to
  `EV_GAS_LEFT` is *exactly* what leaves `EV_STATE_GAS_SPILLED`. So the spill
  counter on its own never goes up here, and `gl + spilled` is unchanged by
  this half.
* `credit_state_gas_refund_increases_sum_min` — the part routed to the
  reservoir is new gas, and this is where `EV_GAS_LEFT + EV_STATE_GAS_LEFT`
  grows.

That is worth stating precisely because it narrows the conservation
obligation. The credit is not uniformly bad for the measure: only the
`amount - min(amount, spilled)` half of it is, and that half is zero whenever
the spill reservoir already covers the refund. What has to be earned is that
the refund never exceeds what was previously charged — which for the five
`SG_NEW_ACCOUNT` sites is the flag threaded through `start_child`, and for
`op_sstore` is still the one argument resting on storage history.

#### Positivity of a computed charge

`charge_gas_decreases_gas` needs `1 <= amount`. The census settles that for 70
of the 87 handlers, because they charge a literal. The remaining 17 *compute*
their charge, and reading them off the source they fall into five shapes:

| shape | handlers |
|---|---|
| `add_sat(base + per * w, x.0)` | `op_keccak`, `op_calldatacopy`, `op_codecopy`, `op_extcodecopy`, `op_returndatacopy`, `op_mcopy` |
| `add_sat(add_sat(base + per * ntopics, x.0), dc.0)` | `op_log` |
| `access_gas_cost(addr)`, alone or `+ G_WARM_ACCESS` | `op_balance`, `op_extcodesize`, `op_extcodehash` |
| `base + per * n` with no `add_sat` | `op_exp` |
| cost paid by the child frame | `op_create`, `op_call`, `op_callcode`, `op_delegatecall`, `op_create2`, `op_staticcall` |

The arithmetic lemmas in `Guest/Gas.lean` cover the first four rows, and all of
them say the same thing --- **the base cost survives** (`op_log`'s row applies
`add_sat_pos` twice, once per nested `add_sat`):

* `add_sat_ge_left` --- saturating addition never loses its left summand, so
  `add_sat(base, extra)` is at least `base` whatever `extra` is and whether or
  not the sum carried. That is exactly what `add_sat` is for.
* `add_sat_pos` --- hence a positive base survives, with **no** side condition.
* `add_pos_of_no_carry`, `linear_cost_pos` --- the same for a plain `+`, which
  *does* need one: with `a = 1` and `b = 2^64 - 1` the machine sum is `0`. That
  asymmetry is the reason the guest reaches for `add_sat` wherever the second
  summand is attacker-influenced, and it is why `op_exp`'s row is separate from
  `op_keccak`'s.
* `linear_cost_pos_of_bound` --- `linear_cost_pos` restated against an upper
  bound `B` on `count` instead of re-deriving the exact no-wrap product each
  time. `op_exp` (`B = 32`), `op_log`'s base step (`B = 4`), and
  `word_metered_cost_pos` below (`B = 2^59`, from `shiftRight_five_lt`) all go
  through this form.

What these do *not* settle is the range facts about the inputs --- `nb <= 32`
for `op_exp`, a bound on `words_of n` for the copy costs. Those are per-handler
and belong with each handler.

#### `access_gas_cost`: the first computed charge proved positive

The `access_gas_cost` row is fully discharged, from the committed AST:

```
fun 1 access_gas_cost(1 addr) {
  var 1 w = is_warm_address(addr);
  if w != 0 { return G_WARM_ACCESS; }   /* 100 */
  warm_address(addr);
  return G_COLD_ACCOUNT_ACCESS;         /* 3000 */
}
```

`access_gas_cost_runs_warm` and `access_gas_cost_runs_cold` are the two paths
at fuel `k + 4`, and `access_gas_cost_charge_pos` combines them: whichever
branch is taken, the function returns exactly `100` or `3000`, exported as the
plain `Nat` bounds `1 <= cost.toNat ∧ cost.toNat <= 3000` rather than the
disjunction they come from --- both halves `access_plus_warm_pos` and
`extcodecopy_charge_pos` need below for `op_extcodesize` / `op_extcodecopy`,
so a caller can hand either bound straight to them instead of re-deriving it
from `access_gas_cost_runs_warm` / `_runs_cold` by hand.

The one callee, `is_warm_address`, remains a hypothesis: it is an `htab` probe,
which needs the load-factor invariant `2*count <= cap` first. What is settled is
that **nothing after it can make the charge zero**, which is the part that had to
be read off the AST rather than off the source. (`access_gas_cost` used to call
`warm_address` itself; since the gas-before-allocation change the caller warms the
address after charging, so that call, and its hypothesis, are gone.)

This is also the first guest function proved whose branch hypothesis is about a
*callee's return value* rather than about memory or a local, so it is the shape
every "did the lookup say yes" test in the guest will take.

#### The word count is bounded by its own shift

`words_of n` is `ceil32(n) >>> 5`. So **whatever it is handed, its result is
below `2^59`** — no fact about `ceil32` is needed, and in particular no
no-wrap assumption about the `n + 31` inside it. `shiftRight_lt` /
`shiftRight_five_lt` is that, and it is what makes the word-metered charges
positive *unconditionally*. Worth recording because the obvious route is to
bound `n`, and `n` is attacker-controlled; the shift makes that unnecessary.

That gives the whole `add_sat` row, with no side conditions:

| handler | charge | lemma | side condition |
|---|---|---|---|
| `op_keccak` | `add_sat(30 + 6*w, x.0)` | `keccak_charge_pos` | none |
| `op_calldatacopy`, `op_codecopy`, `op_returndatacopy`, `op_mcopy` | `add_sat(3 + 3*w, x.0)` | `copy_charge_pos` | none |
| `op_extcodecopy` | `add_sat(acc + 100 + 3*w, x.0)` | `extcodecopy_charge_pos` | `acc <= 3000` |
| `op_log` | `add_sat(add_sat(375 + 375*ntopics, x.0), dc.0)`, or `WORD_MAX` if `dc.1 != 0` | `log_charge_pos` (+ `decide` for the `WORD_MAX` branch) | `ntopics <= 4` |
| `op_balance`, `op_extcodehash` | `access_gas_cost(addr)` | `access_gas_cost_charge_pos` | none |
| `op_extcodesize` | `access_gas_cost(addr) + 100` | `access_plus_warm_pos` | `1 <= acc <= 3000` |
| `op_exp` | `10 + 50*nb`, **no `add_sat`** | `exp_charge_pos` | `nb <= 32` |

`op_calldatacopy` and `op_codecopy` are in the copy row because both delegate
to `copy_from_buffer(3, ...)` (`guest/src/evm.pnk:1344`), which is where the
charge actually happens — neither handler charges anything itself. That is the
sort of thing the census flags and a reader has to resolve.

The side conditions are each a fact about one *other* function, not about
arithmetic: `acc <= 3000` (and, for `op_extcodesize`, `1 <= acc` too) is
`access_gas_cost`'s range, which now follows directly from
`access_gas_cost_charge_pos` rather than from the pair of `_runs` lemmas
above. `ntopics <= 4` is a fact about `op_dispatch`'s opcode decode, and
`nb <= 32` is `u256_byte_length`'s postcondition.

Four of the seven rows above carry a real side condition, and all four are the
same shape underneath: a plain `+` sits somewhere in the charge, either ahead
of whatever `add_sat` is downstream of it or with no `add_sat` at all, and the
bound is what rules out that `+` wrapping.

* `op_extcodecopy`: `acc + 100 + 3*w` is a plain sum before the outer
  `add_sat` against `x.0` ever sees it; it wraps at `acc = 2^64 - 100`.
* `op_log`: its *base* (`375 + 375*ntopics`) is built by a plain `+`/`*`
  before either of its two `add_sat`s sees it, and that base is exactly `0`
  at `ntopics = 2^64 - 1` for any coefficient.
* `op_extcodesize` and `op_exp` have **no** `add_sat` at all --- `acc + 100`
  and `10 + 50*nb` *are* the whole charge, the `add_pos_of_no_carry` /
  `linear_cost_pos` asymmetry showing up directly in the guest's own source.
  `op_extcodesize` needs both halves of `access_gas_cost`'s range: `1 <= acc`
  for positivity, because `acc` is a callee's result rather than a literal,
  and `acc <= 3000` for no-carry. `op_exp` only needs the no-carry half
  (`nb <= 32`), since its base is the literal `10`, already positive by
  `decide`.

`op_keccak` and the copy handlers need none, because `shiftRight_five_lt`
bounds their `w` unconditionally; `op_balance`/`op_extcodehash` need none,
because nothing is added past `access_gas_cost(addr)` itself.

**That leaves the call/create six**, which are different in kind: their cost is
paid by the child frame, so they need the summed-over-frames measure rather
than a positivity lemma.

#### What is still missing for the measure

* **The five `SG_NEW_ACCOUNT` credits**, whose conservation is structural (a
  flag threaded through `start_child`) and so should follow now that calls
  compose.
* **`op_sstore`'s credit**, the one genuinely unearned link — its guard is a
  state condition, not a flag set alongside the charge.
* **The measure summed over live frames**, since gas moves between them.
* **`1 <= amount` is per-opcode.** The census settles 70 of 87 handlers. Of
  the 17 dynamically-metered ones, **eleven now have their arithmetic done** —
  seven with no side condition at all, four modulo a range fact about one
  other function each (see the table above; `op_extcodesize`'s is two-sided,
  both halves from `access_gas_cost_charge_pos`). The **call/create six** are
  what is left, and they
  are different in kind: their cost is paid by the child frame, so they need
  the summed-over-frames measure rather than a positivity lemma.

## What the bound itself needs

The guest's call graph is acyclic (#71), so no recursion-depth argument is
needed; what is left is an iteration bound for each loop. The cpp-expanded
accelerated guest has **257 `while` loops**. By loop condition:

* ~200 are counters against a length or a constant (`i <+ n`, `i < cap`,
  `i < 8`, ...). Their bound is the length or the constant.
* The substantive ones are the de-recursified drivers, where termination is the
  real content:
  * `run_frames` (`evm_calls.pnk:681`) — one iteration per opcode executed
    across all frames, plus one per frame completion.

    **The obvious gas argument does not work as stated.** "Every opcode costs
    at least 1 gas" is false: `op_stop` (`evm.pnk:870`) charges nothing at all,
    it only clears `EV_RUNNING` and advances the pc, and the other frame-ending
    opcodes are in the same position. The repair is that a zero-gas opcode
    *ends its frame*, so it runs at most once per frame — but that turns the
    bound into a case analysis over the whole of `op_dispatch`, showing every
    opcode either charges ≥ 1 gas or clears `EV_RUNNING`. With that, iterations
    ≤ 200M + 2·frames, frames ≤ 1024 deep and ≤ gas/700.

    `lake exe opcode-census` reads that classification off the committed AST.
    It walks `op_dispatch` for every `op_*` handler it can reach — equality
    tests and the range tests that pass an argument (`if op <+ 128 {
    op_push(op - 95); ... }`) alike — and then runs two passes:

    1. the handler's straight-line prefix, following `seq`, `dec` and `decCall`;
    2. a **path-sensitive, interprocedural must-charge analysis** on whatever
       the first pass left open. `mustCharge` holds when every path leaving a
       program has either charged ≥ 1 gas or ended the frame (cleared
       `EV_RUNNING`, or raised — `run_frames` catches `EvmErr` into
       `frame_exception`). It is conservative by construction: a charge inside
       a `while` does not count, since the loop may run zero times, and a
       `return` that has not charged makes the whole program fail. Callee
       facts come from a fixpoint over the acyclic call graph, tracking both
       "charges unconditionally" and "charges if its first argument is ≥ 1" —
       the latter because the charging helpers take the base cost as a
       parameter (`charge_with_memory(3, start, <32,0,0,0>)`), and positivity
       propagates through `add_sat`, which is monotone, but *not* through
       plain `+`, which wraps.

    | | handlers |
    |---|---|
    | charge a literal ≥ 1 gas up front | 60 |
    | end the frame without charging | 3 — `op_stop`, `op_return`, `op_selfdestruct` |
    | charge or end the frame on every path | 7 — `op_mload`, `op_mstore`, `op_mstore8`, `op_sload`, `op_sstore`, `op_push`, `op_revert` |
    | still need a human | 17 |

    **87 handlers, and the only ones that charge nothing up front are frame
    enders** — which is the repaired bound's shape, confirmed rather than
    assumed. `op_dispatch` also falls through to `throw EvmErr 5` for an
    unmatched opcode, which ends the frame too.

    The 17 left are `op_exp`, `op_keccak`, `op_balance`, the four `*copy`
    opcodes, `op_extcodesize`/`op_extcodehash`/`op_extcodecopy`, `op_mcopy`,
    `op_log`, and the six call/create opcodes. They are open for a reason worth
    stating, because it is the same reason as the loop preconditions above:
    their cost is computed rather than constant, so proving it is ≥ 1 needs a
    no-wraparound side condition. `op_keccak`'s
    `cost = add_sat(30 + 6 * w, x.0)` is ≥ 30 only because `6 * w` cannot wrap,
    which holds since `w = words_of(sat_word(size)) ≤ 2^59` — true, but an
    obligation, not an inspection. The call and create opcodes are open for a
    second reason: part of their cost is paid by the child frame.

    The census is syntactic and conservative — a work-list, not a proof.
    Turning "charges ≥ 1" into a semantic fact still needs a lemma about
    `charge_gas`.

    One wrinkle that lemma will have to handle: gas lives in **two** counters.
    `charge_gas` decrements `EV_GAS_LEFT`, but `charge_state_gas`
    (`evm.pnk:249`) draws from `EV_STATE_GAS_LEFT` first and only spills into
    `EV_GAS_LEFT` when that is exhausted, so the measure has to be the sum.
  * the witness-decode machine, MPT insert/delete descent and unwind
    (`mpt.pnk:410,714,857,919,1075`) — bounded by trie depth 64 and the witness
    node count, itself bounded by the input.
  * RLP nested-list validation (`rlp.pnk:177`) — bounded by the item length.
  * `htab_find_slot`/`htab_insert_raw`/`htab_del`
    (`htab.pnk:187,225,298`) — open-addressing probes with wrap-around, which
    terminate *only* under the load-factor invariant `2·count ≤ cap` that
    `htab_set` maintains by calling `htab_grow`. `htab_del`'s `while true`
    needs the same invariant (it stops at the first empty slot). This invariant
    is a genuine proof obligation, not a formality: a full table would spin
    forever.
  * modular-inverse and reduction loops (`secp256k1.pnk:475`, `fp384.pnk:264`,
    `bn254.pnk:1140`, `modexp.pnk:122`, `u256.pnk:400`) — terminate by a
    decreasing valuation or a bounded carry, all with small constant bounds.

Since the per-iteration cost of `run_frames` is itself data-dependent (KECCAK256
over memory, CALLDATACOPY, MCOPY are metered per word), the bound has to be
proved in the parametric shape the issue suggests, `α·gas + β·inputBytes + γ`,
and only then specialised to a constant.

Measured data points on the accelerated build, for calibration: empty input
19,778 steps; a 2,000-byte input rejected at the schema check 24,544; the
minimal well-formed 658-byte input 137,596; typical single-transaction EEST
fixtures 2.4M–3.4M; a BLS/secp256r1-heavy one 13.9M.

One practical limit on measuring more: `guestHostMemory` indexes a `List UInt8`
per byte and the memory map is a chain of closures, so the model is quadratic in
both input length and store count. A 658-byte input takes 0.7 s; one with a
64 KiB witness code does not finish. Anything input-proportional in the bound
will have to be argued rather than measured.
