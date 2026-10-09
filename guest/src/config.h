/* config.h -- guest memory contract (see tools/spike/spike_run.cc and
   guest/runtime/start.S). Pancake has no hex literals, so decimals. */
#define INPUT_ADDR       1073741824   /* 0x40000000: [8B zero meta][8B LE len][blob] */
#define INPUT_LEN_ADDR   1073741832   /* 0x40000008 */
#define INPUT_DATA_ADDR  1073741840   /* 0x40000010 */
/* Largest declared blob length the host contract can actually back: ZisK's
   input region (MAX_INPUT_SIZE = 0x40000000, 1 GiB, core/src/mem.rs -- the
   "128M" comment there is stale) minus the 16 bytes of framing above.
   input_blob() rejects anything larger before allocating or reading payload,
   so len + 8 cannot wrap. */
#define MAX_INPUT_LEN    1073741808   /* 0x40000000 - 16 */
/* ZisK >=1.1.0-alpha reserves RAM_ADDR..+4MB as a guarded stack region (see
   core/src/mem.rs upstream), pushing OUTPUT_ADDR from RAM_ADDR+0x10000
   (0.18.0's address) up by 0x400000. tools/spike/spike_run.cc (a fork of
   evm-asm's) targets this same address so Spike and ZisK agree. */
#define OUTPUT_ADDR      2688614400   /* 0xa0410000 */
#define SCRATCH_BASE     2688618496   /* 0xa0411000: after the output/debug prefix */
#define HEAP_BASE        2701131776   /* 0xa1000000 (= @base) */
#define HEAP_END         2952790016   /* 0xb0000000 */
#define SCRATCH_END      2701127680   /* 0xa0fff000: below the Pancake heap */
/* State journal (state.pnk): 32-byte undo records, reset at every state_fresh_tx.
   Every journal-writing operation costs at least JOURNAL_MIN_GAS regular gas
   (TSTORE, 100), so one transaction writes at most gas/JOURNAL_MIN_GAS records;
   fork.pnk checks at compile time that JOURNAL_CAP covers the largest regular
   gas any one state_fresh_tx scope can run. See docs/JOURNAL-BOUND.md. */
#define JOURNAL_CAP      524288
#define JOURNAL_MIN_GAS  100
#define JOURNAL_SLACK    1024
#define M32              4294967295
#define WORD             8

/* Expression macros (Pancake calls are statements, not expressions). */
#define ROTR32(x, n) (((((x) >>> (n)) | ((x) << (32 - (n))))) & M32)
#define LD_LE32(p) ((ld8 (p)) | ((ld8 ((p) + 1)) << 8) | ((ld8 ((p) + 2)) << 16) | ((ld8 ((p) + 3)) << 24))
#define LD_BE32(p) (((ld8 (p)) << 24) | ((ld8 ((p) + 1)) << 16) | ((ld8 ((p) + 2)) << 8) | (ld8 ((p) + 3)))
#define LD_LE64(p) (LD_LE32(p) | (LD_LE32((p) + 4) << 32))
#define LD_BE64(p) ((LD_BE32(p) << 32) | LD_BE32((p) + 4))
