import Guest.FrameBound

/-!
`lake exe frame-bound [--software] [N]`

Prints the N largest source-level frame bounds (default 15) of the guest's
functions and their maximum `F`; see `Guest.FrameBound` for the estimate.
-/

open Flapjack Guest

def main (args : List String) : IO UInt32 := do
  let software := args.contains "--software"
  let args := args.filter (· != "--software")
  let count := (args[0]?.bind String.toNat?).getD 15
  let program := if software then Software.guestAst else guestAst
  let functions := frameBounds program
  let sorted := functions.toArray.qsort (fun a b => a.2 > b.2)
  IO.println s!"{if software then "software" else "accelerated"} guest: {functions.length} functions"
  IO.println s!"F = max frame bound = {sorted[0]?.map (·.2) |>.getD 0} words"
  IO.println s!"sum of all frame bounds = {(functions.map (·.2)).sum} words"
  for (name, bound) in sorted.toList.take count do
    IO.println s!"  {bound}\t{name}"
  return 0
