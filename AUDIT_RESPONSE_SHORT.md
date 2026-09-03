# Flap Vault Interaction Risk Report

Generated: 2026-09-03 12:35:09 UTC

## Vault Security Rating
**Medium**

Project: ASSAY (`AssayFlapVault`)

Both accepted. Both are documentation that lagged the code, one of the sentences written by us
one round earlier. We swept the repository for the same class rather than fixing only these two:
21 claims about who may do what were wrong, and all 21 are corrected.

---

## Risk Findings

### Finding 1: Curator cannot cancel scheduled conversions despite documentation saying it can
- **Severity:** Medium
- **Confidence:** High
- **Detected by:** doc_review
- **Description:** The `curator` state variable's NatSpec in `AssayFlapVault` states it is "the only account besides the Guardian that may cancel a scheduled conversion." However, `cancelConversion` only permits `msg.sender == _getGuardian()` OR anyone after the `CANCEL_GRACE` period has elapsed (`block.timestamp > s.executeAfter + CANCEL_GRACE`). There is no branch granting the curator any special cancellation right. The inline comment inside `cancelConversion` even confirms this: "The curator used to be able to cancel anything... That path had to close... Before then only the Guardian may act."
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol - curator NatSpec declaration`
  - `src/AssayFlapVault.sol - cancelConversion()`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted. The sentence was ours and it was stale by exactly one round: we wrote it while fixing an earlier finding about this same variable, and then removed the curator's cancel right in the round after, without going back to the line we had just written.

It now reads:

    /// @notice The fixed address `withdrawUnconverted` pays. Set at creation to the token's
    ///         creator, and immutable.
    /// @dev    It holds no privilege at all beyond being that destination. It cannot `endow` —
    ///         that is the Guardian's alone — and it holds no special right over a scheduled
    ///         conversion: until `executeAfter + CANCEL_GRACE` only the Guardian may cancel, and
    ///         after that the curator may do exactly what any address may and nothing more.

The reason the right was removed is worth restating, since the NatSpec now has to carry it: cancelling frees BNB back into `freeTax()`, and `freeTax()` is what `withdrawUnconverted` pays the curator. An account that profits from a conversion never happening must not be able to stop a live one.

**We treated these two as a symptom and swept for the rest.** This is the third round in which prose about who may do what has been contradicted by the `require` that decides it, and the pattern is always the same: a permission moved in one round and a sentence written in an earlier one stayed behind. So rather than fix the two you named, we went through every NatSpec, inline comment, UI-schema label and document in the repository looking for claims of the same kind, and checked each against the code. **21 were wrong. You named 2.** All 21 are fixed. Among the ones you did not name:

- `MAX_ENDOW_SLIPPAGE_BPS`'s NatSpec warned that without a floor "the curator could sandwich the vault's own conversion" — but `endow` is the only caller-supplied floor and it is Guardian-only, so the sentence named an account that cannot reach it.
- `fundTaskFromPool`'s NatSpec described "its fixed reward" and "the same amount for every task". The amount is `rewardPool` at the moment of the call, and the inline comment two lines below it said so.
- `SELF_CHECK.md` documented the recovery as `cancelScheduledEndow(requestId)`, a function that does not exist, with permissions that were also wrong.
- `Tournament`'s `postTask` NatSpec said permissionless posting was a future path. It has been in this version for several rounds.
- Three UI-schema labels read "Collectable now / 现在可领" for values that cannot be collected until settlement.

**And one of them was a sentence we wrote in this round's own fix.** Correcting the `curator` NatSpec, we wrote that it "cannot cancel a scheduled conversion" — absolute, and false, because after `CANCEL_GRACE` anyone may cancel and the curator is among them. It now says the Guardian alone may cancel a live request, and that past the grace the curator may do exactly what any address may.

**What we added so this stops recurring.** `test/Permissions.t.sol` states the whole matrix as eight executable assertions — what the curator cannot do, what only the Guardian may, what is open to anyone, and that `withdrawUnconverted` always pays the curator address and never the caller. Comments cannot be executed, which is why they rot silently. When a permission next moves, that file fails, and whoever moved it has to come and read the sentence they are contradicting.


### Finding 2: README attributes conversion/booking to the curator, but curator has no such privilege
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** The README overview states "the curator converts it to BTCB and books it behind a task." In the implementation, direct conversion via `endow` is `onlyGuardian` (guarded by `require(msg.sender == _getGuardian())`), while `triggerConversion` and `fundTaskFromPool` are permissionless (callable by anyone). The vault's own NatSpec explicitly contradicts the README: "It cannot endow. `endow` is the Guardian's alone... this line used to claim otherwise." The curator therefore has no special conversion or booking authority.
- **Vulnerable Code:**
  - `README.md - What is being audited`
  - `src/AssayFlapVault.sol - endow()`
  - `src/AssayFlapVault.sol - triggerConversion()`
  - `src/AssayFlapVault.sol - fundTaskFromPool()`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted. That sentence now reads "anyone may schedule its conversion to BTCB and book it behind a task", which is what the code does.

One note on where the fix lives, since it matters for re-checking: the archive's README is generated by a heredoc inside `tools/audit-package.sh`, not committed as a file. The correction is at that heredoc, so a diff of `README.md` alone will not show it — the generated copy in the archive will.

The repository's own `README.md` carried a related claim in its "Notes on what this is not" section, saying tasks "are posted by a curator" as the centralised part of this version. That was also out of date: open posting has shipped. It now describes the actual asymmetry — curator and Guardian may post at any time and for any legal window, anyone else only after the previous task has settled and only for at most `OPEN_POST_MAX_SPAN` — and says why the open path is not a claim on the treasury, since `fundTaskFromPool` refuses to move the pool onto a task the project did not publish.

**We treated these two as a symptom and swept for the rest.** This is the third round in which prose about who may do what has been contradicted by the `require` that decides it, and the pattern is always the same: a permission moved in one round and a sentence written in an earlier one stayed behind. So rather than fix the two you named, we went through every NatSpec, inline comment, UI-schema label and document in the repository looking for claims of the same kind, and checked each against the code. **21 were wrong. You named 2.** All 21 are fixed. Among the ones you did not name:

- `MAX_ENDOW_SLIPPAGE_BPS`'s NatSpec warned that without a floor "the curator could sandwich the vault's own conversion" — but `endow` is the only caller-supplied floor and it is Guardian-only, so the sentence named an account that cannot reach it.
- `fundTaskFromPool`'s NatSpec described "its fixed reward" and "the same amount for every task". The amount is `rewardPool` at the moment of the call, and the inline comment two lines below it said so.
- `SELF_CHECK.md` documented the recovery as `cancelScheduledEndow(requestId)`, a function that does not exist, with permissions that were also wrong.
- `Tournament`'s `postTask` NatSpec said permissionless posting was a future path. It has been in this version for several rounds.
- Three UI-schema labels read "Collectable now / 现在可领" for values that cannot be collected until settlement.

**And one of them was a sentence we wrote in this round's own fix.** Correcting the `curator` NatSpec, we wrote that it "cannot cancel a scheduled conversion" — absolute, and false, because after `CANCEL_GRACE` anyone may cancel and the curator is among them. It now says the Guardian alone may cancel a live request, and that past the grace the curator may do exactly what any address may.

**What we added so this stops recurring.** `test/Permissions.t.sol` states the whole matrix as eight executable assertions — what the curator cannot do, what only the Guardian may, what is open to anyone, and that `withdrawUnconverted` always pays the curator address and never the caller. Comments cannot be executed, which is why they rot silently. When a permission next moves, that file fails, and whoever moved it has to come and read the sentence they are contradicting.

---

## Status

- 238 tests across 33 suites, including the new `test/Permissions.t.sol`.
- No token has been launched on either chain.
- **BSC mainnet carries the current code; BSC testnet is behind.** The testnet deploy failed for
  gas — the public BNB testnet faucet is out of funds — so that address still runs an earlier
  revision. The bytecode check in our packaging step is against mainnet and it passes.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x6b220DACd22467e837249344399A5d52951Ae264` | `0xaF10FEE536397243171cee88f4f3273162dC546c` |
| `Tournament` | `0x2d14990a90640435CdbE13BA80e9c57e81d9c5dd` | `0xF9A446c1c69d56FAD9d422d00a71DA2d91A50306` |
| Tax token | not launched | not launched |
