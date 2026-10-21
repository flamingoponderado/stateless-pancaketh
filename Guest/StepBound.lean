import Guest.Model
import Guest.InputDecode
import Flapjack.PanValueFfiFuel

/-!
# Goal 1: the guest terminates within a constant number of Pancake steps

The stateless guest (`guest/src/main.pnk`, cpp-expanded by `guest/build.sh`
with `ZISK_ACCEL`, i.e. the deployed build whose crypto runs on ZisK
accelerators) must terminate, and do so within a fixed number of source-level
Pancake steps, whenever the block it is asked to validate declares a gas limit
of at most `maxBlockGasLimit` (200M) and the input fits ZisK's input region
(`maxInputBytes`, 1 GiB minus the framing). The second premise is essential:
the work done before any gas is consumed (SSZ decoding, witness node
processing, hashing the payload request, rejecting invalid blocks) scales with
the input, not with gas, so no finite bound exists without it, and the constant
is expected to be dominated by that input-proportional term. The step count is the one produced by
flapjack's step-counted source semantics `Flapjack.evalPanValueSteppedProgram`,
applied to the model in `Guest.Model` (`Guest.runGuestStepped`); an accelerator
call counts as one `ExtCall` step.

Together with the step-preserving compilation theorem tracked in
<https://github.com/flamingoponderado/flapjack/issues/352> (a fixed linear relation
between source steps and generated RISC-V instruction steps) this yields a
RISC-V step bound for the compiled guest.

`declaredBlockGasLimit` is filled: `Guest.InputDecode` mirrors the guest's own
decoding of the SSZ input down to the header's `gas_limit`, differentially
validated against the guest by `lake exe input-decode-check`. What is still
`sorry`: the constant `guestPancakeStepBound`, and the theorem.

`TerminatesWithin` asks only that the stepped run *returns* — any control
result, `.raised` included — so a guest that halts on resource exhaustion
satisfies it. That is why `trap_with` ends in `throw TrapErr`: without it a
trap would return in the model and the run would walk off the mapped heap into
an evaluation failure, which no value of the constant could repair. See
`docs/STEP-BOUND.md`.
-/

namespace Guest

open Flapjack

/-- The block gas limit declared by the input: the `gas_limit` field of the
block header inside the SSZ-encoded stateless input (what `fork.pnk` reads
back as `BE_GAS_LIMIT`). `none` when the input does not decode.

`Guest.InputDecode` mirrors the guest's own decoder (`decode_stateless_input`
of `guest/src/ssz.pnk` and everything it calls), so this is `none` on exactly
the inputs on which the guest raises `SszErr`; the field is the payload's
`gas_limit`, which `fork.pnk` copies to `HDR_GAS_LIMIT` and then to
`BE_GAS_LIMIT`. -/
def declaredBlockGasLimit (input : InputBlob) : Option Nat :=
  InputDecode.declaredGasLimit input

/-- Largest declared block gas limit covered by the bound. -/
def maxBlockGasLimit : Nat := 200000000

/-- The constant: an upper bound on the number of Pancake source steps taken by
the guest on any input whose declared block gas limit is at most
`maxBlockGasLimit`. To be fixed by the proof. -/
def guestPancakeStepBound : Nat := sorry

/-- Termination of the stepped guest run within `bound` steps. -/
def TerminatesWithin (input : InputBlob) (bound : Nat) : Prop :=
  ∃ fuel result steps,
    runGuestStepped input fuel = some (result, steps) ∧ steps ≤ bound

/-- Fuel monotonicity for the guest run, from `Flapjack.StepCalculus`: a
successful run keeps its control result and its step count at any larger fuel.
Every compositional step bound needs this, to bring sub-runs proved at their own
fuels to a common one. -/
theorem runGuestStepped_fuel_mono {input : InputBlob} {fuel fuel' : Nat}
    (hfuel : fuel ≤ fuel') {result : PanValueFfiSteppedResult Word HostMemory}
    (hrun : runGuestStepped input fuel = some result) :
    runGuestStepped input fuel' = some result :=
  StepCalculus.evalPanValueFfiProgramStepped_fuel_mono _ _ _ _ hfuel _ _ _ hrun

/-- `TerminatesWithin` weakens to any larger bound, so a parametric bound can be
specialised to the constant. -/
theorem TerminatesWithin.mono {input : InputBlob} {bound bound' : Nat}
    (h : TerminatesWithin input bound) (hle : bound ≤ bound') :
    TerminatesWithin input bound' := by
  obtain ⟨fuel, result, steps, hrun, hsteps⟩ := h
  exact ⟨fuel, result, steps, hrun, Nat.le_trans hsteps hle⟩

theorem terminatesWithin_panSteppedTerminates {input : InputBlob} {bound : Nat}
    (h : TerminatesWithin input bound) :
    PanSteppedTerminates (runGuestStepped input) := by
  obtain ⟨fuel, result, steps, hrun, _⟩ := h
  exact ⟨fuel, result, steps, hrun⟩

/-- **Goal 1.** If the input fits ZisK's input region and declares a block gas
limit of at most `maxBlockGasLimit`, the guest terminates within
`guestPancakeStepBound` Pancake steps. -/
theorem guest_terminates_within_step_bound (input : InputBlob) (gasLimit : Nat)
    (hinput : input.length ≤ maxInputBytes)
    (hdeclared : declaredBlockGasLimit input = some gasLimit)
    (hle : gasLimit ≤ maxBlockGasLimit) :
    TerminatesWithin input guestPancakeStepBound := sorry

end Guest
