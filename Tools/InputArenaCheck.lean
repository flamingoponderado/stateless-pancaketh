import Guest.Model

/-!
`lake exe input-arena-check`

`input_blob` (`guest/src/lib/mem.pnk`) rejects a declared input length above
`MAX_INPUT_LEN` -- ZisK's input region minus the 16-byte framing, `maxInputBytes`
in `Guest.Model` -- with trap code 8, before it allocates or reads any payload.
Without that guard a length near `2^64` makes `alloc(len + 8)` wrap to a small
allocation that `alloc` accepts, and the copy loop then walks off the input
region.

The check runs the guest's own `input_blob`, `alloc` and `trap_with`
declarations from `Guest.guestAst` against a synthetic host memory that answers
the length word only, so it needs no multi-gigabyte blob. It pins all three
outcomes: a length the heap can hold reaches the payload read, a length between
the heap and the input region still traps in `alloc` with code 1, and a length
past the input region traps with code 8.
-/
open Flapjack Guest

/-- Host memory declaring `length` bytes of input, with no payload: every
address in the input region past the length word reads as unmapped, so a run
that reaches the copy loop ends on that read instead of running for hours. -/
def arenaCheckHost (length : Nat) : HostMemory :=
  fun address =>
    if inputLenAddr ≤ address ∧ address < inputLenAddr + 8 then
      (leBytes (BitVec.ofNat 64 length))[(address - inputLenAddr).toNat]?
    else if inputDataAddr ≤ address ∧ address < inputAddr + inputArenaSize then
      none
    else guestHostMemory [] address

/-- `mem_init(); input_blob()` over the guest's own declarations: the crypto
and EVM initialization `main` does is irrelevant here and would dominate the
run. -/
def arenaCheckProgram : List (Decl Word) :=
  (guestAst.filter fun declaration =>
    match declaration with
    | .function fn => ["mem_init", "alloc", "trap_with", "input_blob"].contains fn.name
    | .decl _ name _ =>
        ["heap_ptr", "journal_n", "scratch_ptr", "frame_mem_ptr"].contains name
    | .exnDecl name _ => name == "TrapErr"
    | _ => false) ++
  [.function
    { name := guestEntry, inline := false, exported := false, params := []
      returnShape := .one
      body := .seq (.call (some (none, none)) "mem_init" [])
        (.decCall "input" (.comb [.one, .one]) "input_blob" [] (.return (.const 0))) }]

/-- What a declared length should make the guest do. -/
inductive Expected where
  /-- Past the allocator, ending on the unmapped payload read. -/
  | payloadRead
  /-- `trap_with code`, raising `TrapErr` with `code` in the debug bytes. -/
  | trap (code : UInt8)
  deriving BEq

def Expected.describe : Expected → String
  | .payloadRead => "reached payload read"
  | .trap code => s!"trap {code}"

def checkLength (length : Nat) (expected : Expected) : IO Unit := do
  let initial : PanValueFfiProgramState Word HostMemory :=
    { source := guestInitialState
      ffi := { oracle := guestOracle, state := arenaCheckHost length, ioEvents := [] } }
  let some (result, _) := evalPanValueFfiProgramStepped guestFfiContext initial
      guestPrimitiveHandler guestHostFfi 100000 arenaCheckProgram guestEntry []
      (memoryAccess := some guestMemoryAccess)
    | throw (IO.userError s!"source evaluation failed for length {length}")
  let passed : Bool :=
    match expected, result with
    | .trap code, .raised _ _ _ ffi exception _ =>
        exception == "TrapErr" && ffi.state (outputAddr + 33) == some code
    | .payloadRead, .finalFfi _ _ _ _ event => event.name == .sharedMem .mappedRead
    | _, _ => false
  unless passed do
    throw (IO.userError s!"unexpected source outcome for length {length}")
  IO.println s!"PASS length {length}: {expected.describe}"

/-- The heap (`[HEAP_BASE, HEAP_END)`) minus the 8 bytes `input_blob` adds to
its allocation: the largest length that gets past `alloc`. -/
def maxAllocatableBytes : Nat := (heapEnd - heapBase).toNat - 8

def main : IO Unit := do
  -- Lengths the guest can actually copy reach the payload read unchanged.
  -- (Only small ones here: the copy loop costs a step per word, and the model
  -- would need the fuel and the hours for a real 240 MiB input.)
  for length in [8, 4096] do
    checkLength length .payloadRead
  -- Between the heap and the input region the outcome is unchanged too: the
  -- allocator, not the new guard, is what rejects these.
  for length in [maxAllocatableBytes + 1, maxInputBytes - 1, maxInputBytes] do
    checkLength length (.trap 1)
  -- Past the input region: rejected before allocating or reading payload.
  -- The last two are the lengths whose `len + 8` wraps, which `alloc` alone
  -- would have accepted as a small allocation.
  for length in [maxInputBytes + 1, 2 ^ 35, 2 ^ 64 - 8, 2 ^ 64 - 1] do
    checkLength length (.trap 8)
