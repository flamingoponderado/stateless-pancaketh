# Guest envelope

This note records the deliberate numeric boundaries between the Pancake
guest and the unbounded reference. The reference decodes many RLP scalar
fields into arbitrary-precision Python integers (or the equivalent Lean
Uint), while the guest has 64-bit words, four-limb U256 values, and finite
memory. A guest-only boundary must therefore reject or fail closed rather
than silently truncate a value.

The source links below point at the implementation locations for each
boundary. The line numbers are part of the audit: if one of these checks
moves, this document should be updated with it.

## Summary

| Area | Guest boundary | Guest result |
| --- | --- | --- |
| Header word fields | Values wider than 8 bytes | Header decode error |
| Transaction fees and gas | Fee values wider than 32 bytes; gas wider than 8 bytes | TxErr 13 or TxErr 14 |
| Legacy transaction chain ID | (v - 35) / 2 does not fit a word | TxErr 45 |
| Blob fee exponential | A checked multiplication would exceed 2^256 | Trap while calculating the blob price |
| Account nonce | Account-leaf nonce wider than 8 bytes | MPT account decode error |
| Fee products | gas * price or the fee-plus-value sum exceeds U256 | BlockErr 93, the insufficient-balance path |
| EVM word conversion | A U256 value with non-zero high limbs | Saturates to WORD_MAX; gas or bounds checks decide the outcome |

## Shared word conversion

### RLP word helper

*Reference:* the generic scalar decoder can represent an arbitrary-width
unsigned integer. It does not need to reject an eight-byte boundary merely
to inspect an RLP byte string.

*Guest:* RLP conversion through
[rlp_bytes_to_word at guest/src/lib/rlp.pnk:140](../guest/src/lib/rlp.pnk#L140)
is explicitly a conversion to a Pancake word and rejects n >+ 8 with
RlpErr 20 at
[guest/src/lib/rlp.pnk:143](../guest/src/lib/rlp.pnk#L143). The generic
checker remains unbounded when its maxbytes argument is zero, as shown at
[guest/src/lib/rlp.pnk:158](../guest/src/lib/rlp.pnk#L158).

*Why this is harmless:* callers that need a U256 use the separate U256
decoder; the word helper is only used where the result is required to fit a
machine word. A wider value cannot be represented by that result type, so
rejecting it avoids truncation. The production header and transaction
helpers repeat the same distinction instead of routing U256 fields through
this helper.

## Block-header fields

### Word-sized header scalars

*Reference:* the header RLP path decodes number, gas limit, and gas used as
arbitrary-precision `Uint`. Timestamp is `U256`; blob-gas counters and slot
are `U64`. A canonical `Uint` wider than eight bytes is accepted at decode
time.

*Guest:* [hdr_word_field at guest/src/header.pnk:33](../guest/src/header.pnk#L33)
calls the unbounded header byte parser and rejects a payload wider than eight
bytes with HdrErr 4. [decode_header at guest/src/header.pnk:115](../guest/src/header.pnk#L115)
uses this conversion for number, gas limit, and gas used. Timestamp has an
explicit 32-byte parse followed by the word envelope at
[guest/src/header.pnk:121](../guest/src/header.pnk#L121), which raises HdrErr
12 for values up to 32 bytes that are wider than eight bytes (values wider
than 32 bytes fail the earlier max-width check). Blob gas used and excess blob gas use
the same boundary at
[guest/src/header.pnk:139](../guest/src/header.pnk#L139); the current-fork
slot does so at
[guest/src/header.pnk:152](../guest/src/header.pnk#L152).
The header record documents the complete set of word fields at
[guest/src/types.h:116](../guest/src/types.h#L116).

*Consequence:* a wider `Uint` is outside the guest's 64-bit header envelope,
so the guest can reject an input accepted by the Python reference. This is
especially visible for an earlier witness ancestor: `validate_headers` checks
hash linkage but does not revalidate that ancestor's gas rules. The width
check prevents truncating the integer into a different 64-bit value; it does
not mean the RLP encoding is malformed.

### Header values that are naturally U256

Difficulty and base fee use
[hdr_u256_field at guest/src/header.pnk:48](../guest/src/header.pnk#L48).
Its 32-byte limit is the representation of a U256 field, not an additional
guest-only word envelope. The same distinction applies to fixed-width
byte fields and to the protocol extra-data limit checked at
[guest/src/header.pnk:405](../guest/src/header.pnk#L405): those are schema or
consensus validation rules shared by the reference, not cases where an
unbounded reference integer is being silently narrowed to a word.

## Transaction fields

### Fee Uint values and gas

*Reference:* transaction decoding can hold gas price, priority fee, max fee,
and gas as arbitrary-width Uint values. The reference can therefore carry
these values through decoding before applying transaction and balance
validation.

*Guest:* [tx_scalar_u256 at guest/src/tx.pnk:135](../guest/src/tx.pnk#L135)
rejects an unbounded scalar wider than 32 bytes with TxErr 13. The
legacy gas price and typed dynamic-fee fields take this path at
[guest/src/tx.pnk:341](../guest/src/tx.pnk#L341). Gas is different: the
word conversion at
[guest/src/tx.pnk:351](../guest/src/tx.pnk#L351) uses envcode 14, so a gas
payload wider than eight bytes raises TxErr 14.

*Why this is harmless:* a real transaction's gas is bounded by the block gas
limit; the guest's limit is explicit at
[guest/src/tx.pnk:105](../guest/src/tx.pnk#L105) and is enforced again by
[validate_transaction at guest/src/tx.pnk:955](../guest/src/tx.pnk#L955).
Fee values are carried as U256 after decoding, and a fee wider than 32 bytes
cannot be paid from a U256 account balance. Thus a wider synthetic
transaction is outside the guest's state and execution envelope, while
every representable real-chain transaction follows the same path.

### Legacy chain ID derived from v

*Reference:* for a legacy transaction with v >= 35, the reference computes
(v - 35) / 2 using an arbitrary-precision integer.

*Guest:* [tx_chain_id at guest/src/tx.pnk:727](../guest/src/tx.pnk#L727)
performs the subtraction and shift in U256, then tests the result with
u256_fits_word. A result that does not fit 64 bits raises TxErr 45 at
[guest/src/tx.pnk:744](../guest/src/tx.pnk#L744).

*Why this is harmless:* the recovered chain ID is stored and passed as a
word, and chain IDs used by the supported real chains fit 64 bits. A
legacy signature carrying a larger derived chain ID cannot be represented by
the guest's transaction record, so rejecting it avoids a truncated signing
domain.

### Other transaction width checks

Not every eight-byte check in tx.pnk is a guest-only deviation. Typed
chainId and setCode nonce are declared U64 and authorization nonce is also
stored as a word; those schema checks occur at
[guest/src/tx.pnk:273](../guest/src/tx.pnk#L273) and
[guest/src/tx.pnk:327](../guest/src/tx.pnk#L327). Likewise, nonce values
that do decode as U256 are rejected by the reference transaction validity
rule when they do not fit the account nonce range, at
[validate_transaction at guest/src/tx.pnk:937](../guest/src/tx.pnk#L937).
These are ordinary type or protocol validity checks, not additional
unbounded-reference values being narrowed without a corresponding rule.

## Blob-price arithmetic

### taylor_exponential

*Reference:* the blob base-fee helper evaluates its exponential series with
unbounded integers. An intermediate product may therefore be wider than
256 bits even though the reference can continue the division and produce a
result.

*Guest:* [taylor_exponential at guest/src/header.pnk:273](../guest/src/header.pnk#L273)
uses U256 values. It computes the full product at
[guest/src/header.pnk:285](../guest/src/header.pnk#L285) and traps when any
high product limb is non-zero at
[guest/src/header.pnk:287](../guest/src/header.pnk#L287), rather than using a
wrapped product. The result is used by
[calculate_blob_gas_price at guest/src/header.pnk:301](../guest/src/header.pnk#L301).

*Why this is harmless:* supported real-chain blob-gas values are far inside
the practical range in which the configured exponential result fits U256.
If an astronomical or synthetic header reaches the boundary, trapping fails
closed instead of accepting a wrapped blob price and changing consensus
state. This is a deliberate support envelope, not a claim that arbitrary
unbounded stress inputs are equivalent; supporting such inputs would require
a wider intermediate representation or an explicit reference-compatible
big-integer path.

### Related header fee arithmetic

The base-fee and blob-cost helpers also keep their results in U256:
[calculate_base_fee_per_gas at guest/src/header.pnk:344](../guest/src/header.pnk#L344)
multiplies the U256 parent base fee by a word-sized delta, and
[calculate_excess_blob_gas at guest/src/header.pnk:307](../guest/src/header.pnk#L307)
compares U256 blob-price products. The concrete multiplications are at
[guest/src/header.pnk:360](../guest/src/header.pnk#L360) and
[guest/src/header.pnk:318](../guest/src/header.pnk#L318); these operations
use the low U256 result rather than a full-width overflow error. The reference
comments describe those fee calculations as unbounded. The guest relies on
the real-chain invariant that the header's U256 fee values and the small
protocol deltas remain representable; the header itself cannot encode a fee
wider than 32 bytes. This is a representation invariant to preserve when
extending the supported chain range, not a word truncation of an otherwise
valid ordinary block.

## Account-leaf nonce

*Reference:* account decoding uses Python int.from_bytes for the nonce, so
the reference can represent an account-leaf nonce with more than eight
bytes.

*Guest:* [decode_account_from_leaf at guest/src/mpt.pnk:885](../guest/src/mpt.pnk#L885)
parses the nonce into a word and rejects a payload wider than eight bytes at
[guest/src/mpt.pnk:911](../guest/src/mpt.pnk#L911) with
MPT_E_ACCT_NONCE (21). Account encoding emits the nonce through the word
encoder at
[guest/src/mpt.pnk:954](../guest/src/mpt.pnk#L954).

*Why this is harmless:* the supported account state uses a word-sized nonce,
and transaction execution also requires the transaction nonce to fit that
account range. An over-wide nonce in a witness is therefore outside the
real account-state envelope; rejecting the witness prevents a value from
being truncated before nonce comparisons.

The account balance check at
[guest/src/mpt.pnk:922](../guest/src/mpt.pnk#L922) is different: balance is a
U256 field, so its 32-byte limit is a natural representation limit rather
than the eight-byte guest-only nonce envelope.

## Fee-product overflow

*Reference:* the reference multiplies gas by its price and adds the result
to transaction value using arbitrary-precision integers, then compares the
full amount with the sender balance.

*Guest:* [fee_mul at guest/src/fork.pnk:203](../guest/src/fork.pnk#L203)
computes a full product and records overflow when any high limb is set at
[guest/src/fork.pnk:205](../guest/src/fork.pnk#L205). check_transaction uses
this for the maximum gas fee at
[guest/src/fork.pnk:357](../guest/src/fork.pnk#L357), includes the blob-fee
product at
[guest/src/fork.pnk:381](../guest/src/fork.pnk#L381), and rejects an
overflowing product at
[guest/src/fork.pnk:409](../guest/src/fork.pnk#L409) as BlockErr 93. The
fee-plus-value addition is checked for a carry at
[guest/src/fork.pnk:412](../guest/src/fork.pnk#L412) and uses the same error.

*Why this is harmless:* sender balances and transaction values are U256.
If gas times price, or that amount plus value, exceeds U256, no
representable sender balance can satisfy the reference balance check.
BlockErr 93 is therefore a fail-closed spelling of insufficient balance for
the guest envelope, rather than a modulo-2^256 acceptance.

process_transaction calls check_transaction first at
[guest/src/fork.pnk:449](../guest/src/fork.pnk#L449). Its later fee
accounting consumes the low U256 product limbs at
[guest/src/fork.pnk:460](../guest/src/fork.pnk#L460) and
[guest/src/fork.pnk:603](../guest/src/fork.pnk#L603); the prior overflow
check makes those products safe for transactions that reach execution.

## U256-to-word saturation

### Memory offsets and sizes

*Reference:* EVM stack offsets and lengths are U256 values. A non-zero
memory operation at an offset or size above the guest word range has a
memory-expansion cost beyond any available real transaction gas and must
end out of gas; zero-length operations do not dereference memory.

*Guest:* [sat_word at guest/src/evm.pnk:164](../guest/src/evm.pnk#L164)
returns WORD_MAX when any high U256 limb is non-zero. For memory expansion,
[extend_memory_cost1 at guest/src/evm.pnk:329](../guest/src/evm.pnk#L329)
saturates the operands and returns WORD_MAX when the resulting endpoint is
not representable. [charge_with_memory at guest/src/evm.pnk:397](../guest/src/evm.pnk#L397)
charges that cost before a pointer is used.

The ordering is visible in the representative memory operations:

* mstore and mload charge before using the saturated pointer at
  [guest/src/evm.pnk:892](../guest/src/evm.pnk#L892);
* mcopy charges both extensions before copying at
  [guest/src/evm.pnk:929](../guest/src/evm.pnk#L929);
* calldatacopy/codecopy use the shared checked path at
  [guest/src/evm.pnk:1305](../guest/src/evm.pnk#L1305); and
* returndatacopy performs the gas check and then the bounds check at
  [guest/src/evm.pnk:1399](../guest/src/evm.pnk#L1399).

Thus a non-zero high-limb offset or size becomes an out-of-gas result before
the saturated address can reach frame memory. For a zero-size operation no
bytes are copied, matching the reference's no-op behavior.

### Calls, buffers, and other operands

The same conversion is used by the call family only after its memory
extension cost has been calculated: call gas and argument ranges are handled
at [guest/src/evm_calls.pnk:966](../guest/src/evm_calls.pnk#L966) and
[guest/src/evm_calls.pnk:985](../guest/src/evm_calls.pnk#L985). Saturating a
requested call gas to WORD_MAX is harmless because available frame gas is
also a word and the requested amount is already at least that large.

Finite buffers use zero-padding. calldataload saturates the offset at
[guest/src/evm.pnk:1283](../guest/src/evm.pnk#L1283), and buffer_read returns
zero when that offset is beyond the finite input buffer. blockhash has the
same result for a huge block number through its explicit WORD_MAX check at
[guest/src/evm.pnk:1484](../guest/src/evm.pnk#L1484).

Saturation also preserves the EVM sentinel cases for non-memory operands:
signextend treats a byte index at or above the word width as no extension at
[guest/src/evm.pnk:654](../guest/src/evm.pnk#L654), byte returns zero for an
index at or above 32 at
[guest/src/evm.pnk:758](../guest/src/evm.pnk#L758), and shifts use a value at
least 256 for the zero/sign-fill cases at
[guest/src/evm.pnk:774](../guest/src/evm.pnk#L774).

Finally, modexp length fields are saturated and compared with the protocol's
1024-byte limit at
[guest/src/precompiles.pnk:174](../guest/src/precompiles.pnk#L174). A
high-limb length therefore takes the same out-of-gas path as any length
over the EIP-7823 limit instead of becoming a small allocation.

## What is not a guest-only envelope

The following nearby checks intentionally are not listed as deviations:

* U256 fields wider than 32 bytes, such as account balance and transaction
  value/signature fields, are rejected because their declared type is U256.
* Fixed-width addresses, hashes, bloom, and header fields are checked against
  their wire widths.
* Extra data, transaction nonce validity, access-list shapes, and similar
  checks are protocol/reference validation.

Keeping these cases separate is important: the guest-only envelopes above
are the places where the reference can hold a wider integer but the Pancake
execution record or pointer arithmetic cannot.
