#!/usr/bin/env bash
# build.sh <prog.pnk> <out.elf>
# Pancake source -> RISC-V ELF obeying the evm-asm stateless-guest contract.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CAKE="${CAKE:-$HOME/cakeml/developers/bin/cake}"
COMPILER="${COMPILER:-flapjack}"
AS="${RISCV_AS:-riscv64-unknown-elf-as}"
LD="${RISCV_LD:-riscv64-unknown-elf-ld}"
CPP="${CPP:-cpp}"
src="$1"; out="$2"
b="${out%.elf}"
# Sources are a cpp translation unit (#include / #define for constants).
cpp_debug_args=()
if [[ "${DEBUG:-0}" == "1" ]]; then
  cpp_debug_args=(-DGUEST_DEBUG)
fi
if [[ "${ACCEL:-0}" == "1" ]]; then
  cpp_debug_args+=(-DZISK_ACCEL)   # ZisK accelerator CSRs via FFI stubs in runtime/start.S
fi
"$CPP" "${cpp_debug_args[@]}" -P -w -nostdinc -I "$HERE/src" -x c "$src" | grep -v '^#' > "$b.pp.pnk"
# COMPILER=flapjack (default) uses the Lean 4 port (lake exe flapjack-compile, pinned by
# the flapjack lake dependency); COMPILER=cake uses the bootstrapped/prebuilt cake binary
# instead, emitting the same cake-style assembly frame consumed below.
case "$COMPILER" in
  cake)
    "$CAKE" --pancake --target=riscv < "$b.pp.pnk" > "$b.cake.S"
    ;;
  flapjack)
    ppabs="$(cd "$(dirname "$b.pp.pnk")" && pwd)/$(basename "$b.pp.pnk")"
    (cd "$ROOT" && lake exe flapjack-compile --assembly "$ppabs") > "$b.cake.S"
    ;;
  *)
    echo "build.sh: unknown COMPILER='$COMPILER' (want 'cake' or 'flapjack')" >&2
    exit 1
    ;;
esac
# cake's .S uses C-preprocessor macros (cdecl, makesym); run cpp first.
"$CPP" -P -x assembler-with-cpp "$b.cake.S" > "$b.cake.s"
"$AS" -march=rv64ima -mno-relax -o "$b.cake.o" "$b.cake.s"
"$AS" -march=rv64ima_zicsr -mno-relax -o "$b.start.o" "$HERE/runtime/start.S"
"$LD" -T "$HERE/runtime/guest.ld" -nostdlib --no-relax -e _start \
  -o "$out" "$b.start.o" "$b.cake.o"
echo "built $out"
