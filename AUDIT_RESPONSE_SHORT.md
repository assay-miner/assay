# Flap Vault Interaction Risk Report

Generated: 2026-09-03 10:32:57 UTC

## Vault Security Rating
**Low**

Project: ASSAY (`AssayFlapVault`)

Finding 2 is accepted and fixed. Finding 1 is acknowledged and deliberately not fixed — the
response gives the measured bound and the property we would have to give up to close it.

---

## Risk Findings

### Finding 1: Integer truncation in per-miner bounty split leaves undistributed dust (COM-ROUNDING)
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** rule_review
- **Description:** In AssayFlapVault.collectable/collect, each scoring miner's share is computed as (bounty[taskId] * score) / totalScore with floor division against a fixed pot. The sum of all floored shares is strictly less than the full bounty whenever totalScore does not evenly divide the products, so a small remainder is never paid to any miner. The leftover is not lost to the protocol (reclaimBounty later rolls bounty[taskId] - paid[taskId] back into rewardPool for a future task), but the dust is not distributed to the scoring miners of the current task. (rule COM-ROUNDING)
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol:collectable`
  - `src/AssayFlapVault.sol:collect`

> **Status:** `[ ]` TP　`[ ]` FP　`[ ]` By Design　`[x]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** The mechanism is exactly as described and we are not fixing it. Two reasons, the second of which is the decisive one.

**The size is bounded and we measured it rather than asserting it.** Each miner's share loses less than one wei to the floor, so the entire undistributed remainder is bounded by the number of scoring miners — single-digit wei of a token with eighteen decimals. `test_TheRoundingDustIsBoundedByTheNumberOfScorers` runs a real task to settlement and asserts `bounty - paidOut <= scorers`. It is a measurement, and it will go red if the split ever changes in a way that makes this answer wrong.

**The only fix reintroduces a defect this audit already made us remove.** Paying the remainder out means giving it to whoever collects last, which makes an equal-score payout depend on collection order. That is precisely the property an earlier round of this audit identified in `collect` — a sponsorship landing between two equal-scoring miners paid the second one more than the first — and closing it was the point of freezing the bounty before the first possible collection. Trading that property back for single-digit wei is a bad exchange, and we would rather say so than make the change and hope nobody notices the return trip.

Your own note that the dust is not lost is what makes this comfortable: `reclaimBounty` rolls `bounty - paid` into `rewardPool`, and `rewardPool` funds the next task. The remainder stays prize money for miners; it simply belongs to a later cohort rather than this one.


### Finding 2: Documented "one conversion per epoch" cadence is never enforced (dead `lastConversionAt`, unused `CONVERSION_INTERVAL` rate limit)
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** AssayFlapVault declares `uint256 public lastConversionAt` ("When the last conversion was scheduled") and `CONVERSION_INTERVAL = 5 minutes` with extensive NatSpec asserting that only one conversion may be armed per epoch and that "the earliest next call is a constant away from the last one." However `lastConversionAt` is never written or read anywhere, and `triggerConversion`/`_arm` contain no minimum-interval check. As a result the intended rate limit does not exist: the permissionless `triggerConversion` can be called any number of times per block, each call arming a fresh conversion that reserves a chunk of `freeTax()` up to `maxConvertible()`. The only self-imposed spacing is on the self-arming callback path (which schedules the next request at `block.timestamp + CONVERSION_INTERVAL`); the manual entry point has none.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: state var `lastConversionAt` (declared, never assigned)`
  - `src/AssayFlapVault.sol: triggerConversion()`
  - `src/AssayFlapVault.sol: _arm()`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted, and precisely stated — `lastConversionAt` was declared and then neither written nor read, so the cadence the NatSpec asserts existed only in the NatSpec. `_arm` records the moment it reserves, and the manual entry point checks it:

    require(
        block.timestamp >= lastConversionAt + CONVERSION_INTERVAL,
        unicode"Too soon / 距上次过近"
    );

It does not stand in the way of what `triggerConversion` is for. A chain that has stalled has by definition not armed anything for longer than an interval, so the restart is always available; what is refused is a second arming inside an epoch that already has one.

**This finding is partly a consequence of our own previous fix, and it is worth saying so.** Two rounds ago you showed that `FEE_COVER_MULTIPLE` should not bind the manual path, and we moved it inside the self-arming branch. That was right for the reason you gave — the floor is about spending tax on the scheduler, and a manual caller spends none — but it also removed the only thing that had been limiting how often the manual entry point could be used. The size floor was doing the work of a rate limit by accident. Replacing it with an actual rate limit is what this finding is asking for, and it is the right shape: spacing is a spacing rule, not a size rule.

Tested for the three cases that matter: a second call in the same block is refused, a call one second short of the interval is refused, and a call a full interval later succeeds. Confirmed by deleting the check, where the same second call gets as far as "Nothing to convert / 无可兑换" instead — which is the shape of the finding, the guard being the only thing that had stopped it.

---

## Status

- Every guard added across these rounds was confirmed by breaking it and watching only its own
  test fail.
- No token has been launched on either chain.
- **BSC mainnet carries the current code; BSC testnet is behind.** The testnet deploy failed for
  gas — the public BNB testnet faucet is out of funds — so that address still runs an earlier
  revision. The bytecode check in our packaging step is against mainnet and it passes.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x6b220DACd22467e837249344399A5d52951Ae264` | `0xCB30071bfF091859Ca9f4e4f3fBe68F8bA40e18F` |
| `Tournament` | `0x2d14990a90640435CdbE13BA80e9c57e81d9c5dd` | `0x44A97Dc7E55DA073fCD091542Edff9A43263557A` |
| Tax token | not launched | not launched |
