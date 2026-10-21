import Guest.Model

/-!
`lake exe run-guest [--software] [input] [fuel]`

Runs the guest under flapjack's step-counted stateful-FFI source semantics
exactly as `Guest.runGuestStepped` defines it (the accelerated build; with
`--software`, `Guest.runGuestSoftwareStepped`), and prints the control result,
the step count, and the output region as the guest left it in host memory.

`input` is a guest input as `tools/make-inputs.sh` writes it (the ziskemu
packing: 8-byte little-endian blob length, the blob, zero padding to a multiple
of 8); the blob is what lands at `INPUT_DATA_ADDR`. With no `input` the blob is
empty. `fuel` is the recursion guard (default `2^40`; every loop iteration and
call consumes one unit, so it must exceed the run's total).
-/

open Flapjack Guest

/-- Inverse of the converter's `pack_ziskemu_input`: `[8B LE len][blob][pad]`. -/
def unpackInput (bytes : ByteArray) : Except String InputBlob := do
  if bytes.size < 8 then throw s!"packed input too short: {bytes.size} bytes"
  let length := (List.range 8).foldr (fun i acc => acc * 256 + bytes[i]!.toNat) 0
  if bytes.size < 8 + length then
    throw s!"packed input truncated: length {length}, {bytes.size} bytes"
  pure ((bytes.extract 8 (8 + length)).toList.map fun byte => BitVec.ofNat 8 byte.toNat)

def describe : PanValueFfiControlResult Word HostMemory → String
  | .normal _ _ _ _ => "normal"
  | .returned _ _ _ _ values => s!"returned {values.length} value(s)"
  | .raised _ _ _ _ exception _ => s!"raised {exception}"
  | .broke _ _ _ _ => "broke"
  | .continued _ _ _ _ => "continued"
  | .finalFfi _ _ _ _ event => s!"FFI terminated ({repr event.name}, {repr event.outcome})"

/-- The first `count` bytes of the output region as hex. -/
def outputHex (host : HostMemory) (count : Nat) : String :=
  String.join <| (List.range count).map fun index =>
    match host (outputAddr + BitVec.ofNat 64 index) with
    | some byte =>
        let digits := String.ofList (Nat.toDigits 16 byte.toNat)
        if digits.length < 2 then "0" ++ digits else digits
    | none => "??"

def main (args : List String) : IO UInt32 := do
  let software := args.contains "--software"
  let args := args.filter (· != "--software")
  let input : InputBlob ← match args[0]? with
    | some path => do
        match unpackInput (← IO.FS.readBinFile ⟨path⟩) with
        | .ok blob => pure blob
        | .error message => do
            IO.eprintln message
            return 2
    | none => pure []
  let fuel := (args[1]?.bind String.toNat?).getD (2 ^ 40)
  IO.println s!"{if software then "software" else "accelerated"} guest, input: {input.length} bytes, fuel {fuel}"
  let start ← IO.monoMsNow
  let run := if software then runGuestSoftwareStepped else runGuestStepped
  match run input fuel with
  | none =>
      IO.println s!"run failed (none) after {(← IO.monoMsNow) - start} ms"
      return 1
  | some (result, steps) =>
      IO.println s!"{describe result} in {steps} Pancake steps ({(← IO.monoMsNow) - start} ms)"
      IO.println s!"output[0..80): {outputHex (hostMemoryOf result) 80}"
      return 0
