# Flap Vault Interaction Risk Report

Generated: 2026-09-03 14:05:57 UTC

## Vault Security Rating
**Low**

Project: ASSAY (`AssayFlapVault`)

Finding 1 accepted and fixed. Finding 2 accepted as a real mechanism, acknowledged rather than
fixed — the money is not lost, the contract already supports the mitigation, and closing it
fully would cost something else the finding does not weigh.

---

## Risk Findings

### Finding 1: trigger() re-arm is not wrapped in try/catch despite being documented as best-effort; a revert in _arm's pricing calls can unwind an already-completed conversion
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** In AssayFlapVault.trigger(), the primary conversion is wrapped in try/catch (this.convertForSelf), but the subsequent self-re-arm call `_arm(triggerService.getFee(), 0)` is NOT. The in-code comment states this re-arm is 'Deliberately best-effort. A failure here must not undo a conversion that has already happened.' However, `_arm` performs external router calls that can revert (maxConvertible()/impactBps()/quote() -> router.getAmountsOut, which reverts on zero-reserve / non-existent pair). Only `requestTrigger` inside `_arm` is guarded by try/catch; the pricing calls are not. If any of those revert, the entire trigger() callback reverts, rolling back the delete of the scheduled request and the `reserved -= s.bnbAmount` release (and, in principle, a swap that already succeeded), directly contradicting the documented invariant.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: trigger() final `_arm(triggerService.getFee(), 0);``
  - `src/AssayFlapVault.sol: _arm() calls to maxConvertible()/priceGuard.impactBps()/quote()`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted. Both unguarded calls are real, and the second is exactly the shape the "best-effort" comment already promised would not happen — it just was not actually true.

**The floor computation.** `quote()` calls the router's `getAmountsOut`, which reverts on a pair it cannot price — an emptied pool, in the limit. That call sat bare at the top of `trigger()`, ahead of any try/catch, so its revert took the delete and the `reserved` release with it. It is now behind the same pattern already used for the swap:

    uint256 floorNow = s.minRewardOut;
    try this.quote(s.bnbAmount) returns (uint256 out) {
        uint256 fresh = (out * (10_000 - MAX_ENDOW_SLIPPAGE_BPS)) / 10_000;
        if (fresh > floorNow) floorNow = fresh;
    } catch {
        // The stored floor stands.
    }

Falling back to the stored floor is never worse than what the vault already committed to at arming time, and if the pair is broken enough to make `quote()` revert, the swap right after this is about to fail for the same reason — a failure the existing catch already handles.

**The re-arm.** `_arm` reads the router through `maxConvertible`, `impactBps` and `quote`, none of which it controls, and it was called directly at the tail of `trigger()`. Any one of those reverting took the whole callback down — including a conversion that had just succeeded — which is precisely the "must not undo a conversion that has already happened" the comment two lines above it promised. It now goes through a self-only wrapper, the same pattern as `convertForSelf`:

    try this.rearmSelf() {
    } catch {
        // Re-arming is not available right now. The chain stops arming itself, and
        // triggerConversion restarts it, same as any other reason _arm can decline.
    }

**Tested by breaking each independently.** A mock router — forwards `swapExactETHForTokens` to a working copy of the real one, always reverts on `getAmountsOut` — sits at the router's address for one `trigger()` call. Restoring either direct call in isolation makes the same test fail with the mock's revert string; both guarded, it passes and the completed swap's proceeds land in the pool. Getting the second guard to actually exercise `_arm`'s pricing calls took a correction: the first version of the test left the vault's balance too thin after the swap for `_arm` to reach `maxConvertible()` at all, so breaking that guard passed for the wrong reason — nothing was being tested. It funds the vault again, before the router is broken, so the re-arm has enough free tax to actually try.


### Finding 2: An epoch's converted tax can fail to fund that epoch's task because tax-funding is only permitted during the commit window while conversions are rate-limited
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** fundTaskFromPool() may only assign the reward pool to the current task while `block.timestamp < commitEnd`, but conversions that fill the pool run at most once per CONVERSION_INTERVAL (5 minutes) at times chosen by the Trigger Service. If the pool has not yet received the epoch's converted tax before the current task's commitEnd, that task can never be funded from the pool; the tax instead accumulates in rewardPool and is only assignable to a LATER task. Miners who committed to the current task in reliance on a tax-funded bounty may receive nothing from tax for that epoch.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: fundTaskFromPool() `require(block.timestamp < commitEnd, ...)``
  - `src/AssayFlapVault.sol: CONVERSION_INTERVAL / _arm scheduling cadence`

> **Status:** `[ ]` TP　`[ ]` FP　`[ ]` By Design　`[x]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** The mechanism is real and stated exactly right. It is acknowledged rather than fixed, because the money is not lost, the contract already supports the mitigation, and the actual gap is an operational parameter choice we had not written down or measured before this finding.

**Measured with the shipped numbers**, not argued in the abstract. `tasks/epoch.json` — what the ops flow actually posts — gives a task a sixty-second commit window; `CONVERSION_INTERVAL` is five minutes. A test posts a task on that shipped span, lets a full interval pass, converts tax into the pool, and confirms `fundTaskFromPool` is refused — the money exists, the window is shut. That is the finding, reproduced with the real constants rather than asserted.

**And the contract does not actually block a later catch.** `fundTaskFromPool`'s empty-pool check — `require(amount > 0, ...)` — reverts before the one-shot flag is set, so an attempt against an empty pool costs gas and nothing else; it does not consume the task's chance at a later, non-empty call. A second test posts a task with a commit window as wide as the conversion cadence, and the same sequence — empty attempt, tax arrives, conversion lands — succeeds on the second call within that wider window. The contract was already able to do what this finding is describing as impossible; the shipped `epoch.json` just never gives it enough time to.

**Why we are not changing the code.** The candidates all cost something else. Widening `CONVERSION_INTERVAL`'s effective reach by having the ops script call `fundTaskFromPool` again near a task's `commitEnd` still does not help under the shipped 60-second window — the cadence is five times longer than that, so no in-window retry could catch it regardless of how many times it is called. Shortening `CONVERSION_INTERVAL` reopens the drain this constant exists to prevent: a self-arming conversion spends tax to pay the scheduler, and a shorter interval means more fee-sized windows draining a vault nobody may be trading against, a risk this vault has already been tuned once for. Widening every task's commit window to outlast the cadence works — the second test proves it — but is a deployment choice about `tasks/epoch.json`, not a contract change, and trades against the reason the window is short in the first place: a fast, tight cadence is part of what keeps this machine-only.

**What this costs miners, honestly.** A task can launch with zero BTCB bounty if the pool was empty when `fundTaskFromPool` was called at posting — which the current ops script does once, immediately. It is not the mid-epoch surprise the description could be read as: because that call happens before miners see the task, the bounty is fixed and visible before anyone commits, not withdrawn out from under them afterward. The tax itself is never lost; it accumulates in `rewardPool` until some task's window is open when a call lands, per the existing NatSpec on `fundTaskFromPool`. `test/PoolTiming.t.sol` carries both measurements, so a future change to `CONVERSION_INTERVAL` or the shipped commit window will show up here rather than only in an operational comment.

---

## Status

- Every new guard was confirmed by breaking it and watching only its own test fail.
- No token has been launched on either chain.
- **BSC mainnet carries the current code; BSC testnet is behind.** The testnet deploy failed for
  gas — the public BNB testnet faucet is out of funds — so that address still runs an earlier
  revision. The bytecode check in our packaging step is against mainnet and it passes.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x6b220DACd22467e837249344399A5d52951Ae264` | `0xa8877425AA38b4fD59ebdF445265a24E2d08d32E` |
| `Tournament` | `0x2d14990a90640435CdbE13BA80e9c57e81d9c5dd` | `0x4b5682d350b7975FDD8e16a30933bddF8AcBD7D6` |
| Tax token | not launched | not launched |
