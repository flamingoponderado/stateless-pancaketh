# Allocation audit: gas before memory

**Goal.** For every block whose declared gas limit is at most 200M, no OOM trap
may fire, even on a maliciously crafted block. The OOM traps are `trap_with` codes
1, 6 and 7 (allocator exhaustion, `guest/src/lib/mem.pnk`) and codes 4 and 5
(journal full, `guest/src/state.pnk`; treated as OOM, see below). Code 8
(oversized declared input length) is not an OOM trap: it rejects a length the
host contract cannot back, before any allocation. This needs two
properties:

1. **Ordering.** Gas is charged *before* any allocation whose size or count
   depends on EVM or transaction input. Accounting after the allocation is too
   late.
2. **Footprint.** The RAM layout is large enough for the most memory that 200M gas
   can buy.

The ordering (1) holds for the EVM opcode paths (see "Resolved: charge before
allocate"). The footprint (2) is a RAM-sizing requirement: the guest's memory price
per gas is listed below, and the RAM the challenge needs follows from the highest
price.

## Can OOM occur under 200M block gas?

**Yes, with the current layout.** The heap is 240 MiB and the frame-memory plus
scratch arena is 11.9 MiB. Both are smaller than what 200M gas can fill:

| Region | Current size | Needed for 200M gas | Where the number comes from |
|---|---|---|---|
| heap (`alloc`) | 251,658,240 B (240 MiB), of which the 16 MiB journal | about 1.5 GB from gas-priced use, plus about 1.0 GB that no gas pays for (withdrawals), plus the input and witness: **about 2.5 GB plus the input** | highest heap price, `set_retdata` at about 7.5 B/gas (item 5) over 200M gas is 1.5 GB; withdrawals are item 1, bounded only by the block and input size |
| frame memory plus scratch arena | 12,509,184 B (11.9 MiB) | **about 52 MB per user transaction, about 68 MB per system transaction** (the arena is released after each transaction) | a model of nested frames, see "Frame arena bound" |

The heap is never freed, so its need is the whole block's. The arena is released at
the end of each transaction, so its need is the worst single transaction. Gas
buys memory in different regions, so the heap and arena needs add up in RAM but
are not drawn from the same gas.

Cheapest routes to a trap today (price, then gas to exhaust the region):

* recursion over a 64 KiB contract with stacks and memory grown (items 2 to 4):
  fills the 11.9 MiB arena within about 0.8M gas (the model gives 11.8 MB at 0.7M
  gas and 12.9 MB at 0.85M);
* calls returning increasing sizes (item 5): fills the heap in about 30M to 40M gas;
* distinct `TSTORE` keys (item 6): about 35M to 65M gas;
* a block of minimal transfers (item 7): about 9,500 of them, with the journal, is
  close to the whole heap.

**How to read the prices.** Prices are in bytes of memory per unit of gas. A higher
number is cheaper memory for an attacker. For anything that happens once per
transaction the price uses the cheapest transaction, a plain transfer at 21,000 gas.
Except where marked "measured" or "modeled", figures come from a static audit
(three read-only reviews of `guest/src/*.pnk`) and hand arithmetic from struct and
hash-table sizes. Confirm each with a run before relying on it. A trapping run
records `heap_ptr` at `OUTPUT_ADDR + 40` (see `trap_with`), which can be used to
measure.

## Block gas limit reaches each transaction before it runs

The header's gas limit is stored in `be + BE_GAS_LIMIT` (`fork.pnk` `execute_block`
setup) and re-applied before every transaction:

* `check_transaction` (`fork.pnk`, called at the start of `process_transaction`
  before any execution) recomputes the remaining gas from the running totals:
  `regular_avail = limit - BO_GAS_USED` and `state_avail = limit - BO_STATE_GAS_USED`.
  It rejects the block (`BlockErr 80`/`81`) if `min(TX_MAX_GAS_LIMIT, tx.gas) > regular_avail`
  or `tx.gas > state_avail`.
* `BO_GAS_USED` and `BO_STATE_GAS_USED` are updated after each transaction
  (`fork.pnk`), so the next transaction sees what is left.
* The gas handed to execution is `mgas = min(TX_MAX_GAS_LIMIT - intrinsic, tx.gas - intrinsic)`
  plus a reservoir for the rest, so regular execution gas plus intrinsic gas never exceeds
  `min(TX_MAX_GAS_LIMIT, tx.gas)`, hence never exceeds `regular_avail`.

So a transaction cannot run with more gas than the block has left; the limit is not
compared only after the fact. Two caveats: regular and state gas are separate budgets
(each bounded by the limit), so memory driven by state-gas operations can add to memory
driven by regular gas; and the number of transactions is bounded only by the 21,000
intrinsic gas each, which is why the per-transaction heap use (item 7 below) matters.

## Trap classes under the challenge statement

The challenge lets a submission behave arbitrarily when the original source
diverges or OOM-traps, but requires it to match when the original terminates or
traps for a non-OOM reason. So the guest's traps split as follows
(`trap_with` sites):

| Code | Site | Reason | Class |
|---|---|---|---|
| 1 | `alloc` (`lib/mem.pnk`) | heap exhausted, or `n` would wrap `p + n` | OOM |
| 6 | `frame_mem_alloc` | EVM frame-memory arena exhausted | OOM |
| 7 | `scratch_alloc` | scratch arena exhausted | OOM |
| 4, 5 | `jset`, `jdel` (`state.pnk`) | fixed-size journal full | OOM (treated as OOM; made unreachable at 200M gas, see [JOURNAL-BOUND.md](JOURNAL-BOUND.md)) |
| 2 | `lib/arith.pnk` | division by zero | non-OOM |
| 3 | `header.pnk` | base-fee arithmetic overflow | non-OOM |
| 8 | `input_blob` (`lib/mem.pnk`) | declared input length above `MAX_INPUT_LEN` (ZisK's input region minus the 16-byte framing) | non-OOM |

An OOM trap hands the submission a free pass on that block, so it must be unreachable
for blocks at or below 200M gas; and a change here must not turn a non-OOM trap into
an OOM one or the reverse.

## Memory map

| Arena | Region | Size | Used for |
|---|---|---|---|
| heap (`alloc`) | `[0xa1000000, 0xb0000000)` | 240 MiB | persistent state, logs, tables, code, input, the 16 MiB journal |
| EVM frame memory (`frame_mem_alloc`) | bottom of `[0xa0411000, 0xa0fff000)` | shares 11.9 MiB with scratch | per-frame EVM `MEMORY` |
| scratch (`scratch_alloc`) | top of the same region | | per-frame struct, stack, jumpdest bitmap, tables |

## Memory price per gas

The footprints that gas does not pay for, ordered by price, cheapest memory first,
with the one item that costs no gas at the top. The highest price in each region
sets the RAM in the table above.

| # | Where | Problem | Price (bytes per gas) | Upper limit at 200M declared block gas | Limit it reaches |
|---|---|---|---|---|---|
| 1 | `process_withdrawals` (`fork.pnk`), `decode_payload` (`ssz.pnk`) | The withdrawal count is bounded only by the 8 MiB block-size check, not by gas. Each withdrawal allocates about 3 KB (account copy, journal key copy, a BAL account of about 1.4 KB) | **not priced in gas**: about 3 KB each at 0 gas | **about 1.0 GB**: at most 335,544 withdrawals (8,388,608 B over the 25-byte minimum RLP encoding) at about 3 KB each. `payload_header` checks the block size before it encodes the withdrawals or builds any trie, so a larger block is rejected without allocating for them; only the 16-byte slices that the SSZ decode makes per transaction and per withdrawal come first | heap, from the block size or input size alone |
| 2 | `frame_new`, `compute_jumpdests` (`evm.pnk`) | Every live call frame allocates about 2.9 KB of fixed setup (frame struct, 1 KiB stack, 1 KiB memory, message, continuation record, tables) plus a jumpdest bitmap of `code_n / 8` bytes, up to 8,200 B for 64 KiB code. The bitmap is rebuilt per frame, not cached. A warm CALL costs 100 gas and charges for none of it | about 110 B/gas (64 KiB code, about 11.1 KB per call at 100 gas); about 30 B/gas for small code | **5.3 MB** per user transaction (16.76M gas), **5.7 MB** per system transaction (30M gas); the arena is released after each transaction, so 200M gas does not multiply it. Modeled: depth stops near 480 frames because each CALL consumes gas and forwards 63/64 | scratch arena. On its own this stays under the arena (about 5 MB, see the upper limit), because each CALL consumes gas and forwards 63/64 so depth stops near 480 frames; combined with items 3 and 4 it overruns the arena |
| 3 | `stack_push` (`evm.pnk`) | The stack doubles from 32 to 1,024 words and keeps every old buffer until the frame exits: about 62 KB for a full stack, which 513 pushes reach (the 513th doubles the capacity to 1,024) | about 55 to 60 B/gas (513 `PUSH0` at 2 gas is 1,026 gas, plus a 100-gas CALL, for about 62 KB) | **25.8 MB** per user transaction, **28.5 MB** per system transaction (includes the frame setup of item 2). Modeled | scratch arena, with items 2 and 4, within about 0.8M gas |
| 4 | `extend_memory` (`evm.pnk`) | Paid EVM memory costs 3 gas per 32-byte word plus `w^2/512`, which is about 10 B/gas for small sizes, and the quadratic term is paid per frame, so splitting memory across live frames is cheaper than one large frame. **The way `extend_memory` grows the arena can double the consumption**: it doubles the capacity although the arena grows in place, so up to twice the paid size is taken (see below) | **about 20 B/gas** (the paid price is about 10 B/gas; the doubling roughly doubles the memory actually taken, for example 1,056 bytes costs 101 gas and takes 2,048) | **40.1 MB** per user transaction, **55.1 MB** per system transaction (includes the frame setup of item 2). Modeled, with the doubling slack counted at its worst. Items 2 to 4 combined: 51.6 MB and 67.6 MB | frame-memory arena, with items 2 and 3, within about 0.8M gas across live frames |
| 5 | `set_retdata` (`evm_calls.pnk`) | Allocates `n + 8` bytes on the heap whenever a call returns more than the frame's retdata buffer holds, and never frees it. The callee paid memory for `n` once; the parent pays about 100 gas for the CALL. Calls that return increasing sizes leak each size | about 7.5 B/gas at the best size, so about 1.5 GB at 200M gas (a run of calls returning 32 B, 64 B, 96 B and so on; the ratio stays between 6.9 and 7.5 for sizes from 7 KB to 32 KB) | **about 1.5 GB** (7.5 B/gas over 200M gas) | heap, after about 30M to 40M gas |
| 6 | `TSTORE` (`evm.pnk`, `state.pnk` `set_transient_storage`, `jset`, `htab_grow`) | With distinct keys, 100 gas allocates the value, a journal key copy, and a transient-table slot of about 81 B; `htab_grow` doubles the table and abandons the old arrays | about 4 to 7 B/gas | **about 1.5 GB** (7.4 B/gas at the worst point of the table doubling, over 200M gas); a 16.76M-gas transaction alone is about 100 MB | heap, after about 35M to 65M gas |
| 7 | per transaction: `state_fresh_tx` (`state.pnk`), `process_transaction` (`fork.pnk`) | Allocates the transaction's tables on the heap and never releases them; there is no `heap_release` in the transaction loop | about 1.15 B/gas: **measured** minimum of 24,232 B per transaction over 370 sampled cases with 1 to 16 transactions, against 21,000 gas for the cheapest transaction. 9,523 minimal transfers is about 231 MB, plus the 16.8 MB journal, close to the 251.7 MB heap before the input, witness and BAL | **about 231 MB**: 9,523 transactions (200M / 21,000) at the measured 24,232 B each | heap |
| 8 | `SSTORE` rewrite of an existing slot, `TSTORE` of an existing key (`state.pnk` `set_storage`, `jset`) | Each write allocates a 32 B value and a 56 B journal key copy and never frees them | 0.9 B/gas (88 B per 100 gas), about 176 MB at 200M gas | **about 176 MB** (200M / 100 gas writes, 88 B each) | heap |
| 9 | BAL (`bal.pnk` `bal_ensure_account`) | About 1.4 KB per touched account, plus about 0.3 to 1 KB in the block-state tables. The EIP-7928 item limit is checked only after execution | about 0.55 to 1 B/gas (cold account access is 2,600 gas) | **about 190 MB**: 77,000 cold accounts (200M / 2,600 gas) at about 2.4 KB | heap |
| 10 | `htab_grow`, `lst_push` | Always allocate on the heap and abandon the old arrays, so a grown table costs about twice its final size. Accessed sets, transient storage, BAL and logs all grow this way | about 0.3 B/gas (a storage-key slot is about 81 B at 2 to 4 slots per entry, doubled for abandoned arrays, against 2,100 gas per cold key) | **about 60 MB** | heap |
| 11 | `compute_state_root` (`block.pnk`) | Re-decodes the witness storage trie per modified account, with no `heap_release` | about 0.2 to 0.5 B/gas (unverified) | **about 40 to 100 MB** (unverified) | heap |
| 12 | `op_log`, receipts (`evm.pnk`, `block.pnk`) | Log records and receipt buffers persist. `LOG0` is 375 gas for about 150 B; the receipt buffer and bloom are about 650 B per transaction | about 0.4 B/gas for `LOG0`; about 0.03 B/gas for the receipt of a cheapest transaction | **about 80 MB** for `LOG0` (533,000 logs at about 150 B), plus about 6 MB of receipts for 9,523 transactions | heap |

Accepted: precompile output buffers are never released (blake2f with 0 rounds is
the worst, about 100 MB at 200M gas, about 0.5 B/gas). That cost is paid for in gas.

### Frame arena bound

Multiplying the highest arena price (about 110 B/gas for jumpdest bitmaps) by the
gas would give gigabytes, but two limits cap it: call depth is at most 1,024 frames,
and each call forwards at most 63/64 of the remaining gas, so deep frames have almost
none. The worst case was modeled by dynamic programming over call depth. Each frame
may pay gas for a stack grown to 62 KB and for EVM memory grown to a power-of-two
capacity (the doubling slack of item 4 counted at its worst), costs 100 gas plus a
little for the CALL, and passes `(gas - spent) * 63/64` to the next frame. Frame
base size is 11,134 B (2,934 B of setup and an 8,200 B bitmap for 64 KiB code).

| One transaction's regular gas | Largest arena use |
|---|---|
| 16,756,216 (a user transaction at `TX_MAX_GAS_LIMIT` less the 21,000 intrinsic) | **51.6 MB** |
| 30,000,000 (a system transaction, `SYSTEM_TRANSACTION_GAS`) | **67.6 MB** |
| 5,000,000 | 29.4 MB |
| 1,000,000 | 14.0 MB |
| 200,000 | 6.2 MB |

Restricting what a frame may pay for gives the per-item limits used in the table
above (`tools/arena-bound.py --items base|stack|mem|all`), user transaction then
system transaction:

| Frames may pay for | User tx | System tx |
|---|---|---|
| nothing extra (item 2) | 5.3 MB | 5.7 MB |
| stack growth (items 2 and 3) | 25.8 MB | 28.5 MB |
| EVM memory growth (items 2 and 4) | 40.1 MB | 55.1 MB |
| all of them | 51.6 MB | 67.6 MB |

Even a 1M-gas transaction models at 14 MB, over the 11.9 MiB arena. The model is
not a measurement: it assumes the pre-state holds a 64 KiB contract that calls
itself, ignores gas spent on anything but the CALL, stack and memory, and takes the
worst doubling slack at every frame. Treat it as an upper bound to size the arena.
`tools/arena-bound.py` reproduces the table (it needs numpy); re-run it if the frame
layout or the 63/64 rule changes.

### What `extend_memory` is

`extend_memory(expand_by)` in `evm.pnk` grows the current call frame's EVM `MEMORY`
by `expand_by` bytes and zero-fills them. It is called, after the gas for the
expansion has been charged, by every opcode that touches memory:

* `MLOAD`, `MSTORE`, `MSTORE8` (through `charge_with_memory`), `MCOPY`, `KECCAK256`,
  `LOG0` to `LOG4`;
* the copy opcodes `CALLDATACOPY`, `CODECOPY` (through `copy_from_buffer`),
  `EXTCODECOPY` and `RETURNDATACOPY`;
* `RETURN` and `REVERT` (the returned range);
* `CREATE` and `CREATE2` (the init-code range);
* `CALL`, `CALLCODE`, `DELEGATECALL` and `STATICCALL` (the input and output ranges).

The cost side is `extend_memory_cost1` and `extend_memory_cost2`, which return the
quadratic gas and `expand_by`; callers charge that and then call `extend_memory`.
If the new length exceeds the frame's capacity, `extend_memory` asks the arena for
`max(2 * cap, new_len + 1024) - cap` more bytes through `frame_mem_alloc`. Each frame
starts with 1,024 bytes of capacity. The frame is always the top frame when it
expands (a child's memory is released before the parent resumes), so the arena can
grow in place and the doubling gains nothing; it only raises the footprint to as
much as twice the paid size.

## Ways to lower the RAM requirement

* Allocate the per-transaction tables once and clear them (`htab_clear`) instead
  of calling `htab_new` per transaction (item 7).
* A transaction-scoped arena, reset in `state_fresh_tx`, for objects that live no
  longer than the transaction: journal key copies, TSTORE and SSTORE values, tables
  (items 5, 6, 7, 8, 10).
* Cache the jumpdest bitmap per code hash instead of rebuilding it per frame
  (item 2; it also scans all of the code on every call, which is unpaid compute).
* Preallocate stacks at a fixed `STACK_DEPTH_LIMIT * 32 KiB` region, or charge for
  frame footprint, and size the frame arena for the worst case (items 2, 3, 4).
  Grow frame memory in steps of the paid size, not by doubling (item 4).
* Count BAL items and withdrawals before allocating (items 1, 9).
* Add stress tests (about 9,500 minimal transfers; a 16.7M-gas TSTORE loop; deep
  recursion over a large contract; deep recursion with full stacks) and record the
  final `heap_ptr` and arena pointers.

## Resolved: charge before allocate

The EVM opcode paths now charge gas before they allocate or insert into the
accessed sets. All of these keep the total gas charged unchanged; only the order
differs.

| Site | Before | After |
|---|---|---|
| `access_gas_cost` users: BALANCE, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH (`evm.pnk`) | warmed the address (can grow a table), then charged | charge, then `warm_after_charge` |
| `op_sload` | `alloc(32)` key and warm insert, then charge | preallocated key buffer; charge, then warm |
| `op_sstore` | `alloc(32)` key, `check_gas`, warm, state reads, charge | preallocated key buffer; charge the access cost, warm, state reads, then charge the rest |
| `op_tload`, `op_tstore` | `alloc(32)` key | preallocated key buffer |
| `op_log` | `alloc` topics before the gas charge | charge (with a stack-depth check kept first), then allocate |
| `op_create2` | `alloc(32)` salt before the charge | charge, then allocate |
| `op_selfdestruct` (`evm_calls.pnk`) | `check_gas`, warm, state reads, charge | charge base and cold cost, warm, state reads, charge the rest |
| `op_call`, `op_callcode`, `op_delegatecall`, `op_staticcall` | `check_gas`, warm, delegation read (`alloc(24)`), code read, then charge | charge access, transfer and memory cost; warm; delegation read, charge delegation cost; then code read |
| `pre_modexp` header | `alloc(96)` before the gas is known | preallocated header buffer |
| `alloc`, `frame_mem_alloc`, `scratch_alloc` | `p + n` could wrap | explicit overflow check before the add |

The preallocated buffers (`evm_key_buf`, `pre_hdr_buf`) are safe to reuse: every
callee that keeps a key copies it (`jset`, `htab_set`).

Reads of account and storage state still happen after the access cost is
charged but before the state-dependent remainder (for example SSTORE's write
cost, SELFDESTRUCT's new-account cost). The remainder depends on the values
read, so the read cannot move. Those reads allocate small cached records only.

## Resolved: shared accessed sets

Before, every CALL/CREATE copied both accessed sets (addresses and storage keys)
into scratch, sized by table capacity, and a successful child merged its whole copy
back with `htab_union_into`. A child that grew a table on the heap and reverted left
the parent's table unchanged, so the same growth could be repeated for a few gas
each. Now there is one pair of tables per transaction, shared by all frames
(`child_message` passes the pointers on):

* `frame_new` records the entry count of each table when a frame starts
  (`EV_ACC_ADDRS_N`, `EV_ACC_KEYS_N`).
* A failed child calls `rollback_child_access`, which `htab_truncate`s each table
  back to that count. Insertion only appends to a table's iteration order and
  nothing else deletes from a table in use, so the entries added since the mark are
  exactly the tail of the order. No separate undo log is needed.
* A successful child leaves its entries in place, so the parent's own rollback
  covers them. The merge is gone.

Memory in use is one table per transaction, whose entries are each paid for (a cold
access costs at least 1,900-2,600 gas). A table that has grown keeps its capacity
after a rollback, so warm-then-revert does not regrow it on each call. Per-call cost
no longer depends on how large the accessed sets are.

## Resolved: journal-full traps

Codes 4 and 5 were reachable: a system transaction runs 30M gas outside the block
gas limit, and TSTORE writes one journal record per 100 gas, which is 300,000
records against a cap of 262,144. `JOURNAL_CAP` is now 524,288, a compile-time check
ties it to `TX_MAX_GAS_LIMIT` and `SYSTEM_TRANSACTION_GAS`, and the journal is reset
after each withdrawal. The derivation and the assumptions to re-check are in
[JOURNAL-BOUND.md](JOURNAL-BOUND.md).
