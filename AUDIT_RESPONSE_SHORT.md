# Flap Vault Interaction Risk Report

Generated: 2026-09-02 14:15:05 UTC

## Vault Security Rating
**Low**

Project: ASSAY (`AssayFlapVault`)

Both findings accepted. Finding 1 was fixed in the round before this report was generated.
Finding 2 is fixed at its cause — the ordering inside the callback — rather than by improving the
manual recovery it points at.

---

## Risk Findings

### Finding 1: FEE_COVER_MULTIPLE worthiness gate is applied to the manual conversion path, contradicting its documented intent and blocking small manual conversions
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** In AssayFlapVault._arm the check `if (amount <= fee * FEE_COVER_MULTIPLE) return 0;` is placed OUTSIDE the `if (incoming == 0)` block, so it runs on BOTH the self-arming path (called from trigger with incoming==0) and the manual path (called from triggerConversion with incoming==msg.value). The in-code comment explicitly states this gate should only bind the self-arming path (which spends tax to pay the scheduler): "The manual path pays its own fee and is not bound by this; only the arming that spends tax is." The actual code binds the manual path too. As a result, triggerConversion() returns 0 and reverts with "Nothing to convert" whenever the free unconverted tax is <= 10 × schedulerFee, even though the manual caller pays the scheduler fee themselves out of msg.value. The documented manual recovery path (restart the conversion cadence when the scheduler has stalled) is therefore unavailable for any tax balance below ~10 fees.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol:_arm (the `if (amount <= fee * FEE_COVER_MULTIPLE) return 0;` line placed outside the `if (incoming == 0)` block)`
  - `src/AssayFlapVault.sol:triggerConversion`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted, and fixed in the round before this report was generated, so the code reviewed here is one commit behind. The check sits inside `if (incoming == 0)` now, where the comment always said it belonged.

The floor exists because the self-arming path buys the scheduler out of tax. A caller who supplies the fee spends none of the vault's, so the premise never reached them — and your framing of the consequence is what settled it for us: `triggerConversion` is the restart when the self-arming chain has stopped, and refusing it whenever free tax is under ten fees refused it in exactly the low-activity case a stall comes from. A guard that disables the recovery path under the conditions that produce the failure is not a conservative guard.

Residual, stated rather than buried: anyone may now force a small conversion at their own expense, moving that BNB from the side that returns to the curator into the side only a scoring miner can take out. The caller pays the fee every time, the impact and slippage guards still refuse sizes the pair cannot take, and the BTCB still funds this project's own tasks.

Tested in both directions: a window under the floor converts when the caller pays the fee, and the same window still does not arm itself out of tax.


### Finding 2: A permanently-failing scheduled conversion keeps `reserved` inflated, understating freeTax until manually cancelled
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** AssayFlapVault._arm increases `reserved` by the armed BNB amount and stores a ScheduledEndow. `reserved` is only reduced when the request is executed via trigger() or explicitly dropped via cancelConversion(). If a scheduled request can never be executed (e.g., its stored floor can no longer be met by the pool and every retry reverts inside trigger's swap), the reserved amount stays elevated. freeTax() = balance - reserved is then understated for as long as the request lingers, shrinking every subsequent endow, _arm, and withdrawUnconverted sizing. Recovery exists via cancelConversion (curator or guardian), so no funds are permanently lost, but until it is called the free pool is silently reduced.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol:_arm (reserved += amount)`
  - `src/AssayFlapVault.sol:trigger`
  - `src/AssayFlapVault.sol:cancelConversion`
  - `src/AssayFlapVault.sol:freeTax`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted, and fixed at the cause rather than the recovery.

Two notes on the description first, both in your favour. The recovery you point at is narrower than it was when you wrote this: `cancelConversion` is no longer the curator's, because the previous round showed a curator could cancel every conversion as it was armed and take the whole tax through `withdrawUnconverted`. It is the Guardian's, plus anyone once a request is an hour past due. So the manual recovery still exists, but it needs Flap or a passer-by rather than us — which makes "until it is called" a worse wait, not a better one, and is part of why we did not stop there.

The cause is the ordering inside `trigger`. It deletes the request and releases `reserved` and only then swaps, so a revert in the swap undoes all three. That is what leaves the request sitting there with `reserved` inflated. The swap is now reached through a self-only external wrapper so the callback can survive it failing:

    try this.convertForSelf(s.bnbAmount, floorNow) {
        // Converted.
    } catch {
        emit ConversionFailed(requestId, s.bnbAmount, floorNow);
    }

The delete and the release stand. The BNB is left exactly where it was before the request existed — free — and the same callback arms it again below at a floor priced now rather than at one the market has left behind, which is the condition that made the request unexecutable in the first place. No human is required and no waiting period applies.

The failure is emitted, never swallowed. A conversion that did not happen is visible on chain as one that did not happen, and `ConversionFailed` carries the amount and the floor that was refused.

**A trade we are making deliberately, because it reverses an earlier decision of ours.** A test in our suite asserted the old behaviour as a feature, with this reasoning: the Trigger Service records EXECUTED once a callback returns, so a callback that returns after a failed swap leaves `retryTrigger` refusing that request for ever. Reverting kept the request alive to be retried. That is true, and it is the reason the code was written that way.

We are giving up `retryTrigger` for this path. It buys nothing here: a retry would re-attempt the same stored floor the market has already left behind, which is what made the request unexecutable. Re-arming inside the same callback prices a new floor against the market that just moved, so the recovery the retry was for happens immediately and without the service's involvement. What the old design actually protected against — a conversion consumed with nothing booked — cannot arise, because nothing is consumed: the BNB returns to free tax before the new request is armed. If that arming is itself refused (too small a window, an impact bound the pair cannot take), the BNB simply sits as free tax and `triggerConversion` restarts the chain.

Tested by pushing the pair hard enough that the stored floor genuinely cannot be met — the test asserts the floor is unreachable before relying on it — then firing the callback and checking the request is cleared and nothing is reserved that the vault could not pay. Confirmed by removing the try/catch, where the callback fails with `PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT` exactly as you describe.

One correction to our own first attempt at that test, since it bears on reading the result: it asserted `reserved == 0` after the failure, which is wrong — the callback re-arms before returning, so a healthy vault has a fresh reservation at that point. The invariant that actually broke is that `reserved` exceeded what the vault could pay, and that is what it asserts now.

---

## Status

- Every new guard was confirmed by breaking it and watching only its own test fail.
- No token has been launched on either chain.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x68c2656B23329d4Ceee87d39a1038EA5aAdAa222` | `0x3B0da8368e01b516703E65Ce9Ba9be9d1B327341` |
| `Tournament` | `0xe432Ad772b2498631f7e1806BD0D33c35b184233` | `0x57e19122B5136E4808A6351B20286D07a67Fb522` |
| Tax token | not launched | not launched |
