import RiscvZkvm.Rv64.ZiskAccel
import Guest.Basic

/-!
# Reference semantics of the ZisK accelerators on word memory

The `ZISK_ACCEL` build of the guest replaces its software crypto with foreign
calls that `guest/runtime/start.S` turns into `csrrs` on ZisK precompile CSRs.
Each accelerator reads operands through pointers in a parameter block and
writes its result back into memory. The semantics below are those of
`RiscvZkvm.Rv64.MachineState.csrsWrite`/`csrsValid` (the same functions
evm-asm uses), transcribed from the machine's word memory to flapjack's
structured source memory: `readWords` fails (`none`) where the machine model
would reject the access, and `acceleratorEffect` fails where `csrsValid` would
trap (zero modulus, unreduced or degenerate curve inputs, bad SIGMA index).

This is no longer what the guest's semantics runs. Every accelerator call follows
CakeML's foreign-call convention (`docs/ACCEL-FFI.md`) and is specified by the byte-level
functions of `Guest.AccelFfi`, which `lake exe accel-ffi-check` compares with
`acceleratorEffect` on concrete vectors. `acceleratorEffect` stays as that reference.

| `@name`                    | CSR   | effect |
| --- | --- | --- |
| `keccakf`                  | 0x800 | moved to the foreign-call interface, see `Guest.AccelFfi` |
| `arith256mod`, `bn_arith256` | 0x802 | `p → {a*, b*, c*, m*, d*}` (4 limbs): `*d := (a·b + c) mod m` |
| `secpadd`                  | 0x803 | `p → {p1*, p2*}`: `*p1 := p1 + p2` on secp256k1 (chord) |
| `secpdbl`                  | 0x804 | point at `p` doubled in place (tangent) |
| `sha256f`                  | 0x805 | moved to the foreign-call interface, see `Guest.AccelFfi` |
| `bn_g1_add`, `bn_g1_dbl`   | 0x806, 0x807 | as secp over the BN254 field |
| `bn_fp2_add/sub/mul`       | 0x808–0x80a | `p → {f1*, f2*}`: `*f1 := f1 ∘ f2` in BN254 Fp2, `u² = −1` |
| `bls_arith384`             | 0x80b | 6-limb `arith256mod` |
| `bls_g1_add`, `bls_g1_dbl` | 0x80c, 0x80d | as secp over BLS12-381 (6 limbs) |
| `bls_fp2_add/sub/mul`      | 0x80e–0x810 | BLS12-381 Fp2 |
| `blake2bround`             | 0x819 | `p → {idx, state*, input*}`: one BLAKE2b round on the 16-word state |
-/

namespace Guest

open Flapjack RiscvZkvm.Rv64

/-- Read `n` consecutive word cells at `p` (8-byte stride); `none` if any is
unmapped or holds a struct. -/
def readWords (memory : Memory) (p : Word) (n : Nat) : Option (List Word) :=
  (List.range n).mapM fun i =>
    match memory (p + BitVec.ofNat 64 (8 * i)) with
    | some (.word w) => some w
    | _ => none

/-- Write consecutive word cells at `p`. -/
def writeWords (memory : Memory) (p : Word) : List Word → Memory
  | [] => memory
  | w :: ws => writeWords (updatePanValueMemory memory p (.word w)) (p + 8) ws

def readWord (memory : Memory) (p : Word) : Option Word := do
  match ← readWords memory p 1 with
  | [w] => pure w
  | _ => none

/-- `*d := (a·b + c) mod m` over `limbs`-limb operands (CSRs 0x802, 0x80b). -/
def arithModEffect (limbs : Nat) (memory : Memory) (p : Word) : Option Memory := do
  let pa ← readWord memory p
  let pb ← readWord memory (p + 8)
  let pc ← readWord memory (p + 16)
  let pm ← readWord memory (p + 24)
  let pd ← readWord memory (p + 32)
  let a ← readWords memory pa limbs
  let b ← readWords memory pb limbs
  let c ← readWords memory pc limbs
  let m ← readWords memory pm limbs
  let _ ← readWords memory pd limbs
  let modulus := Accel.leLimbsToNat m
  if modulus = 0 then none
  else pure (writeWords memory pd (Accel.natToLeLimbs limbs (Accel.arith256Mod
    (Accel.leLimbsToNat a) (Accel.leLimbsToNat b) (Accel.leLimbsToNat c) modulus)))

/-- `*p1 := p1 + p2` by the chord formula (CSRs 0x803, 0x806, 0x80c). -/
def curveAddEffect (prime limbs : Nat) (memory : Memory) (p : Word) : Option Memory := do
  let p1 ← readWord memory p
  let p2 ← readWord memory (p + 8)
  let pt1 ← readWords memory p1 (2 * limbs)
  let pt2 ← readWords memory p2 (2 * limbs)
  if Accel.ptValid prime limbs pt1 && Accel.ptValid prime limbs pt2 &&
      !(Accel.leLimbsToNat (pt1.take limbs) == Accel.leLimbsToNat (pt2.take limbs)) then
    pure (writeWords memory p1 (Accel.curveAddL prime limbs pt1 pt2))
  else none

/-- Point at `p` doubled in place by the tangent formula (CSRs 0x804, 0x807, 0x80d). -/
def curveDblEffect (prime limbs : Nat) (memory : Memory) (p : Word) : Option Memory := do
  let pt ← readWords memory p (2 * limbs)
  if Accel.ptValid prime limbs pt && !(Accel.leLimbsToNat (pt.drop limbs) == 0) then
    pure (writeWords memory p (Accel.curveDblL prime limbs pt))
  else none

/-- `*f1 := f1 ∘ f2` in Fp2 (CSRs 0x808–0x80a, 0x80e–0x810). -/
def complexEffect (op : Nat → Nat → List Word → List Word → List Word)
    (prime limbs : Nat) (memory : Memory) (p : Word) : Option Memory := do
  let f1 ← readWord memory p
  let f2 ← readWord memory (p + 8)
  let a ← readWords memory f1 (2 * limbs)
  let b ← readWords memory f2 (2 * limbs)
  if Accel.ptValid prime limbs a && Accel.ptValid prime limbs b then
    pure (writeWords memory f1 (op prime limbs a b))
  else none

/-- One BLAKE2b round: `p → {idx, state*, input*}` (CSR 0x819). -/
def blake2bEffect (memory : Memory) (p : Word) : Option Memory := do
  let index ← readWord memory p
  let pstate ← readWord memory (p + 8)
  let pinput ← readWord memory (p + 16)
  let state ← readWords memory pstate 16
  let input ← readWords memory pinput 16
  if index.toNat < 10 then
    pure (writeWords memory pstate (Accel.blake2bRound index.toNat state input))
  else none

/-- Effect of the accelerator named by the guest's `@name` on memory, with `p`
the first `ExtCall` argument (the parameter-block pointer, `a0` of the stub).
`none` for an unknown name, for the accelerators that go through the ordinary
foreign-call interface (`Guest.acceleratorBytes`), or an input the machine model
would trap on. -/
def acceleratorEffect (name : FunName) (p : Word) (memory : Memory) : Option Memory :=
  match name with
  | "arith256mod" | "bn_arith256" => arithModEffect 4 memory p
  | "secpadd" => curveAddEffect Accel.secpP 4 memory p
  | "secpdbl" => curveDblEffect Accel.secpP 4 memory p
  | "bn_g1_add" => curveAddEffect Accel.bn254P 4 memory p
  | "bn_g1_dbl" => curveDblEffect Accel.bn254P 4 memory p
  | "bn_fp2_add" => complexEffect Accel.complexAddL Accel.bn254P 4 memory p
  | "bn_fp2_sub" => complexEffect Accel.complexSubL Accel.bn254P 4 memory p
  | "bn_fp2_mul" => complexEffect Accel.complexMulL Accel.bn254P 4 memory p
  | "bls_arith384" => arithModEffect 6 memory p
  | "bls_g1_add" => curveAddEffect Accel.bls12P 6 memory p
  | "bls_g1_dbl" => curveDblEffect Accel.bls12P 6 memory p
  | "bls_fp2_add" => complexEffect Accel.complexAddL Accel.bls12P 6 memory p
  | "bls_fp2_sub" => complexEffect Accel.complexSubL Accel.bls12P 6 memory p
  | "bls_fp2_mul" => complexEffect Accel.complexMulL Accel.bls12P 6 memory p
  | "blake2bround" => blake2bEffect memory p
  | _ => none

end Guest
