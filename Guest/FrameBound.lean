import Guest.Ast
import Guest.SoftwareAst

/-!
# Source-level stack frame estimate

An oracle-free upper estimate of each guest function's stack frame, in words,
assuming every variable is spilled:

  frame(f) ≤ words(params) + words(all `var` declarations in the body)
             + max over statements of (expression nodes in that statement)
             + 1

The middle term bounds the temporaries `crep_to_loop` introduces (one per
expression node, counter restarted per statement); the trailing `+ 1` is
`word_to_stack`'s frame slot. Struct-shaped variables count their flattened
word size. Handler frames cost 3 more slots at run time (wordLang's
`stack_size_frame`), a per-call-depth constant rather than per function.

The intended second goal, once flapjack's stepped semantics report the maximum
call depth of a run (flapjack issue on the cost record): for declared block gas
at most 200M, `8 · (guestMaxFrameBound · maxCallDepth + 3 · handlers)` plus the
runtime shim's constant stays below the 240 MB stack region, and the bump
allocators' high-water marks stay below their regions.
-/

open Flapjack

namespace Guest.FrameBound

def words : Shape → Nat := Shape.shapeSize

partial def expNodes : Exp α → Nat
  | .const _ | .var _ _ | .baseAddr | .topAddr | .bytesInWord => 1
  | .rStruct fields => 1 + (fields.map expNodes).sum
  | .rField _ e | .nField _ e | .load _ e | .load32 e | .loadByte e => 1 + expNodes e
  | .nStruct _ fields => 1 + (fields.map (fun f => expNodes f.2)).sum
  | .op _ args | .panOp _ args => 1 + (args.map expNodes).sum
  | .cmp _ l r | .shift _ l r => 1 + expNodes l + expNodes r

/-- Expression nodes evaluated by one statement (not descending into nested
statements), an upper bound on the temporaries live at once. -/
def stmtExpNodes : Prog α → Nat
  | .dec _ _ v _ | .assign _ _ v | .raise _ v | .return v => expNodes v
  | .primitive _ _ args | .call _ _ args | .decCall _ _ _ args _ => (args.map expNodes).sum
  | .store a v | .store32 a v | .storeByte a v | .shMemStore _ a v => expNodes a + expNodes v
  | .ite c _ _ | .while c _ => expNodes c
  | .extCall _ a b c d => expNodes a + expNodes b + expNodes c + expNodes d
  | .shMemLoad _ _ _ a => expNodes a
  | _ => 0

/-- Words of every variable declared in the body (each `var`, `var = f()`,
and handler variable). -/
partial def declaredWords : Prog α → Nat
  | .dec _ shape _ body => words shape + declaredWords body
  | .decCall _ shape _ _ body => words shape + declaredWords body
  | .seq a b => declaredWords a + declaredWords b
  | .ite _ a b => declaredWords a + declaredWords b
  | .while _ b => declaredWords b
  | .call (some (_, some (_, _, handler))) _ _ => 1 + declaredWords handler
  | _ => 0

partial def maxTemps : Prog α → Nat
  | .seq a b => max (maxTemps a) (maxTemps b)
  | .ite c a b => max (expNodes c) (max (maxTemps a) (maxTemps b))
  | .while c b => max (expNodes c) (maxTemps b)
  | .dec _ _ v b => max (expNodes v) (maxTemps b)
  | .decCall _ _ _ args b => max (args.map expNodes).sum (maxTemps b)
  | .call info _ args =>
      max (args.map expNodes).sum (match info with
        | some (_, some (_, _, handler)) => maxTemps handler
        | _ => 0)
  | s => stmtExpNodes s

def frameBound (f : FunDecl α) : Nat :=
  (f.params.map (fun p => words p.2)).sum + declaredWords f.body + maxTemps f.body + 1

end Guest.FrameBound


namespace Guest

open Flapjack

/-- Frame bound of every function of a program. -/
def frameBounds (program : List (Decl Word)) : List (FunName × Nat) :=
  program.filterMap fun
    | .function f => some (f.name, FrameBound.frameBound f)
    | _ => none

/-- `F`: the largest frame bound over the (accelerated) guest's functions. -/
def guestMaxFrameBound : Nat :=
  (frameBounds guestAst).foldl (fun acc entry => max acc entry.2) 0

theorem guestMaxFrameBound_eq : guestMaxFrameBound = 348 := by
  native_decide

end Guest
