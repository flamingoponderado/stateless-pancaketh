import Guest.Model

/-!
`lake exe trace-guest [--software] [input] [fuel]`

Debugging aid for `Guest.runGuestStepped` (with `--software`,
`Guest.runGuestSoftwareStepped`). Runs the guest on `input` (same format as
`run-guest`); if the run fails (`none`) or ends in an uncaught exception,
re-executes the guest statement by statement, descending into the call that
fails or raises, down to the leaf statement, and prints the call chain with
argument values and the locals in scope at the leaf.

Each level re-runs the statements of one function body once, so the cost is
roughly the run time times the call depth.
-/

open Flapjack Guest

structure Env where
  locals : VarName → Option (PanValue Word)
  globals : VarName → Option (PanValue Word)
  memory : Memory
  ffi : FfiState HostMemory

structure Ctx where
  st : PanValueProgramState Word
  fuel : Nat

abbrev Result := PanValueFfiSteppedResult Word HostMemory

def Ctx.run (ctx : Ctx) (env : Env) (p : Prog Word) : Option Result :=
  evalPanValueFfiProgramSteps guestFfiContext guestPrimitiveHandler guestHostFfi ctx.st.structs
    ctx.st.functions ctx.st.baseAddress ctx.st.topAddress ctx.st.bytesInWord ctx.fuel
    env.locals env.globals env.memory env.ffi p
    (memoryAccess := some guestMemoryAccess)

def Ctx.eval (ctx : Ctx) (env : Env) (e : Exp Word) : Option (PanValue Word) :=
  evalPanValueExp ctx.st.structs env.locals env.globals env.memory ctx.st.baseAddress
    ctx.st.topAddress ctx.st.bytesInWord e (some guestMemoryAccess)

def Ctx.evals (ctx : Ctx) (env : Env) (es : List (Exp Word)) : Option (List (PanValue Word)) :=
  evalPanValueExps ctx.st.structs env.locals env.globals env.memory ctx.st.baseAddress
    ctx.st.topAddress ctx.st.bytesInWord es (some guestMemoryAccess)

partial def chain : Prog Word → List (Prog Word)
  | .seq a b => a :: chain b
  | p => [p]

partial def boundNames : Prog Word → List VarName
  | .dec n _ _ b => n :: boundNames b
  | .decCall n _ _ _ b => n :: boundNames b
  | .shMemLoad _ _ n _ => [n]
  | .seq a b => boundNames a ++ boundNames b
  | .ite _ a b => boundNames a ++ boundNames b
  | .while _ b => boundNames b
  | .call (some (_, some (_, v, h))) _ _ => v :: boundNames h
  | _ => []

partial def showVal : PanValue Word → String
  | .word w => w.toHex
  | .rStruct fs => "<" ++ ", ".intercalate (fs.map showVal) ++ ">"
  | .nStruct n _ => s!"<{n}>"

partial def showExp : Exp Word → String
  | .const v => v.toHex
  | .var _ n => n
  | .rStruct fs => "<" ++ ", ".intercalate (fs.map showExp) ++ ">"
  | .rField i e => s!"{showExp e}.{i}"
  | .nStruct n _ => s!"{n}\{..}"
  | .nField n e => s!"{showExp e}.{n}"
  | .load _ a => s!"lds({showExp a})"
  | .load32 a => s!"ld32({showExp a})"
  | .loadByte a => s!"ld8({showExp a})"
  | .op o as => "(" ++ s!" {repr o} ".intercalate (as.map showExp) ++ ")"
  | .panOp _ as => "(" ++ " * ".intercalate (as.map showExp) ++ ")"
  | .cmp c l r => s!"({showExp l} {repr c} {showExp r})"
  | .shift s l r => s!"({showExp l} {repr s} {showExp r})"
  | .baseAddr => "@base"
  | .topAddr => "@top"
  | .bytesInWord => "@biw"

def showStmt : Prog Word → String
  | .skip => "skip"
  | .dec n _ v _ => s!"var {n} = {showExp v}"
  | .assign _ n v => s!"{n} = {showExp v}"
  | .primitive n _ as => s!"{n} = __add_with_carry__({", ".intercalate (as.map showExp)})"
  | .store a v => s!"st {showExp a}, {showExp v}"
  | .store32 a v => s!"st32 {showExp a}, {showExp v}"
  | .storeByte a v => s!"st8 {showExp a}, {showExp v}"
  | .seq _ _ => "seq"
  | .ite c _ _ => s!"if {showExp c}"
  | .while c _ => s!"while {showExp c}"
  | .break => "break"
  | .continue => "continue"
  | .call _ f as => s!"{f}({", ".intercalate (as.map showExp)})"
  | .decCall n _ f as _ => s!"var {n} = {f}({", ".intercalate (as.map showExp)})"
  | .extCall f c _ _ _ => s!"@{f}({showExp c}, ...)"
  | .raise e v => s!"raise {e} {showExp v}"
  | .return v => s!"return {showExp v}"
  | .shMemLoad _ _ n a => s!"!ld {n}, {showExp a}"
  | .shMemStore _ a v => s!"!st {showExp a}, {showExp v}"
  | .tick => "tick"
  | .annot _ _ => "annot"

/-- Which outcome we are hunting for. -/
inductive Target where
  | failure
  | exception

def Target.hit : Target → Option Result → Bool
  | .failure, none => true
  | .exception, some (.raised _ _ _ _ _ _, _) => true
  | _, _ => false

def Env.normal (env : Env) : Result → Option Env
  | (.normal l g m f, _) => some { env with locals := l, globals := g, memory := m, ffi := f }
  | _ => none

/-- Descend to the leaf statement producing the target outcome. -/
partial def locate (ctx : Ctx) (target : Target) (env : Env) (p : Prog Word) (pad : String) :
    IO (Option (Prog Word × Env)) := do
  match p with
  | .seq _ _ =>
      let mut env := env
      for s in chain p do
        let r := ctx.run env s
        if target.hit r then return ← locate ctx target env s pad
        match r.bind env.normal with
        | some next => env := next
        | none => return none
      return none
  | .ite c a b =>
      match ctx.eval env c with
      | some (.word v) => locate ctx target env (if v != 0 then a else b) pad
      | _ => return some (p, env)
  | .dec n _ v b =>
      match ctx.eval env v with
      | some val => locate ctx target { env with locals := updatePanValueMap env.locals n val } b pad
      | none => return some (p, env)
  | .decCall n _ f as b =>
      let r := ctx.run env (.call none f as)
      if target.hit r then return some (p, env)
      match r with
      | some (.returned _ g m ffi [v], _) =>
          let next : Env := { locals := updatePanValueMap env.locals n v, globals := g,
                              memory := m, ffi := ffi }
          locate ctx target next b pad
      | some (.raised _ _ _ _ e v, _) =>
          IO.println s!"{pad}(callee of `{showStmt p}` raised {e} {showVal v})"
          return some (p, env)
      | _ => return none
  | .while c b =>
      let mut env := env
      let mut iter := 0
      repeat
        match ctx.eval env c with
        | some (.word v) =>
            if v == 0 then return none
            let r := ctx.run env b
            if target.hit r then
              IO.println s!"{pad}(loop iteration #{iter})"
              return ← locate ctx target env b pad
            match r with
            | some (.normal l g m f, _) | some (.continued l g m f, _) =>
                env := { locals := l, globals := g, memory := m, ffi := f }
                iter := iter + 1
            | _ => return none
        | _ => return some (p, env)
      return none
  | _ => return some (p, env)

partial def traceFun (ctx : Ctx) (target : Target) (env : Env) (f : FunName)
    (args : List (PanValue Word)) (depth : Nat) : IO Unit := do
  let pad := "".pushn ' ' (2 * depth)
  let some (params, body) := lookupPanFunction f ctx.st.functions
    | IO.println s!"{pad}{f}: not found"
  let some locals := bindPanValueParameters params args
    | IO.println s!"{pad}{f}: cannot bind parameters"
  IO.println s!"{pad}{f}({", ".intercalate (args.map showVal)})"
  match ← locate ctx target { env with locals := locals } body pad with
  | none => IO.println s!"{pad}  (outcome not reproduced inside the body)"
  | some (s, env) =>
      IO.println s!"{pad}  at: {showStmt s}"
      match s with
      | .call _ g argExps | .decCall _ _ g argExps _ =>
          match ctx.evals env argExps with
          | some vals => traceFun ctx target env g vals (depth + 1)
          | none =>
              IO.println s!"{pad}  argument evaluation failed:"
              for e in argExps do
                IO.println s!"{pad}    {showExp e} = {(ctx.eval env e).map showVal |>.getD "<fail>"}"
      | _ =>
          for v in (params ++ boundNames body).eraseDups do
            if let some val := env.locals v then IO.println s!"{pad}    {v} = {showVal val}"

def unpackInput (bytes : ByteArray) : Except String InputBlob := do
  if bytes.size < 8 then throw s!"packed input too short: {bytes.size} bytes"
  let length := (List.range 8).foldr (fun i acc => acc * 256 + bytes[i]!.toNat) 0
  if bytes.size < 8 + length then
    throw s!"packed input truncated: length {length}, {bytes.size} bytes"
  pure ((bytes.extract 8 (8 + length)).toList.map fun byte => BitVec.ofNat 8 byte.toNat)

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
  let program := if software then Software.guestAst else guestAst
  let some st := evalPanValueDeclarations guestInitialState program (some guestMemoryAccess)
    | do IO.println "declarations failed"; return 1
  let ctx : Ctx := { st, fuel }
  let target ← match runProgramStepped program input fuel with
    | none => do IO.println "run failed (none); tracing the failing statement"; pure Target.failure
    | some (.raised _ _ _ _ e v, steps) => do
        IO.println s!"run raised {e} {showVal v} after {steps} steps; tracing the raise"
        pure Target.exception
    | some (.finalFfi _ _ _ _ event, steps) => do
        IO.println s!"run terminated by the FFI after {steps} steps: {repr event.name} {repr event.outcome}"
        return 1
    | some (r, steps) => do
        IO.println s!"run ended normally after {steps} steps ({match r with
          | .returned _ _ _ _ vs => s!"returned {vs.length} value(s)" | _ => "other"}); nothing to trace"
        return 0
  let env : Env := { locals := fun _ => none, globals := st.globals, memory := st.memory,
                     ffi := guestFfiState input }
  traceFun ctx target env guestEntry [] 0
  return 0
