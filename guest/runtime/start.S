# start.S -- bare-metal runtime shim for a Pancake program running as a
# ZisK-style stateless guest under tools/spike/spike_run (or ziskemu).
#
# Contract (see tools/spike/spike_run.cc):
#   input  at 0x40000000: [8B zero meta][8B LE len][blob]
#   output at 0xa0410000: SSZ StatelessValidationResult bytes
#   halt   : ecall with a7 = 93
#
# The Pancake program itself reads/writes those regions with shared-memory
# loads/stores (!ldw / !st8 ...), so the only FFI it needs is `halt`.
.option norelax
.option norvc
.section .text
.globl _start
_start:
    li   sp, 0xa00f0000          # small C-style stack for the shim / FFI stubs
    la   t0, cml_heap
    li   t1, 0xa1000000          # Pancake heap start (@base)
    sd   t1, 0(t0)
    la   t0, cml_stack
    li   t1, 0xb0000000          # Pancake heap end / stack start
    sd   t1, 0(t0)
    la   t0, cml_stackend
    li   t1, 0xbf000000          # Pancake stack end
    sd   t1, 0(t0)
    call cml_main
    j    cml_exit

.globl cml_exit
cml_exit:
    li   a7, 93
    ecall
1:  j 1b

# FFI: @halt(...) -> clean halt.
.globl ffihalt
ffihalt:
    j    cml_exit

# FFI: @trap(@base, code, @base, 0) -- signal an unrecoverable guest error;
# write the marker and code bytes and halt so the harness sees a deterministic
# (wrong) output.  Pancake's trap_with helper writes the additional metadata.
# 0xa0410000 matches guest/src/config.h's OUTPUT_ADDR.
.globl ffitrap
ffitrap:
    li   t0, 0xa0410000
    li   t1, 0xEE
    sb   t1, 32(t0)
    sb   a1, 33(t0)
    j    cml_exit

#ifdef ZISK_ACCEL
# ---- ZisK accelerator FFI stubs ----------------------------------------------
# Each stub implements one foreign call of docs/ACCEL-FFI.md.  `@name(c, 0, a, n)` has
# an empty configuration, and the operands lie at fixed offsets from the array `a`, which
# arrives in a2 (the ExtCall arguments are a0 = c, a1 = 0, a2 = a, a3 = n).  The ZisK
# CSRs take absolute pointers, so a stub builds the pointer block they expect on its own
# stack from a2, issues the CSR, and returns.  The Pancake side therefore holds no
# addresses in the array: the effect is a function of the array's bytes alone.  Only t0,
# t1 and the stack below sp are touched, so the argument registers are preserved.
# tools/spike/spike_run implements the same CSRs (tools/spike/zisk_accel.cc).

# The CSR takes the operand's pointer itself: the array is the operand.
.macro ACCEL_DIRECT name, csr
.globl ffi\name
ffi\name:
    csrrs x0, \csr, a2
    ret
.endm

# The CSR takes a block {a2, a2 + off}.
.macro ACCEL_PTRS2 name, csr, off
.globl ffi\name
ffi\name:
    addi sp, sp, -16
    sd   a2, 0(sp)
    addi t0, a2, \off
    sd   t0, 8(sp)
    mv   t0, sp
    csrrs x0, \csr, t0
    addi sp, sp, 16
    ret
.endm

# The CSR takes a block of five pointers, `stride` bytes apart from a2.
.macro ACCEL_PTRS5 name, csr, stride
.globl ffi\name
ffi\name:
    addi sp, sp, -48
    sd   a2, 0(sp)
    addi t0, a2, \stride
    sd   t0, 8(sp)
    addi t0, a2, 2*\stride
    sd   t0, 16(sp)
    addi t0, a2, 3*\stride
    sd   t0, 24(sp)
    addi t0, a2, 4*\stride
    sd   t0, 32(sp)
    mv   t0, sp
    csrrs x0, \csr, t0
    addi sp, sp, 48
    ret
.endm

# Keccak-f[1600] on the 200-byte state; point doubling in place on the 64- or 96-byte point.
ACCEL_DIRECT keccakf,    0x800
ACCEL_DIRECT secpdbl,    0x804
ACCEL_DIRECT bn_g1_dbl,  0x807
ACCEL_DIRECT bls_g1_dbl, 0x80d

# One SHA-256 compression: array = 32-byte packed state, then the 64-byte block.
ACCEL_PTRS2 sha256f,     0x805, 32

# Point addition (p1 += p2) and Fp2 operations (f1 = f1 op f2): two operands back to back.
ACCEL_PTRS2 secpadd,     0x803, 64
ACCEL_PTRS2 bn_g1_add,   0x806, 64
ACCEL_PTRS2 bn_fp2_add,  0x808, 64
ACCEL_PTRS2 bn_fp2_sub,  0x809, 64
ACCEL_PTRS2 bn_fp2_mul,  0x80a, 64
ACCEL_PTRS2 bls_g1_add,  0x80c, 96
ACCEL_PTRS2 bls_fp2_add, 0x80e, 96
ACCEL_PTRS2 bls_fp2_sub, 0x80f, 96
ACCEL_PTRS2 bls_fp2_mul, 0x810, 96

# d = (a * b + c) mod m: array = a, b, c, m, d, each `stride` bytes.
ACCEL_PTRS5 arith256mod,  0x802, 32
ACCEL_PTRS5 bn_arith256,  0x802, 32
ACCEL_PTRS5 bls_arith384, 0x80b, 48

# One BLAKE2b round: array = SIGMA row (a value, 8 bytes), 128-byte state, 128-byte
# message.  The CSR's block is {row, state*, message*}.
.globl ffiblake2bround
ffiblake2bround:
    addi sp, sp, -32
    ld   t1, 0(a2)
    sd   t1, 0(sp)
    addi t0, a2, 8
    sd   t0, 8(sp)
    addi t0, a2, 136
    sd   t0, 16(sp)
    mv   t0, sp
    csrrs x0, 0x819, t0
    addi sp, sp, 32
    ret
#endif
