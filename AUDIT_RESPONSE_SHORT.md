# Flap Vault Interaction Risk Report

Generated: 2026-09-02 05:01:09 UTC

## Vault Security Rating
**Medium**

Project: ASSAY (`AssayFlapVault`)

All three findings accepted. Finding 3 was already fixed before this report was generated.
Finding 1 is the third round on `fundTaskFromPool` and the first two narrowings were both
insufficient; the response says how, because the pattern is more useful than the patch.

---

## Risk Findings

### Finding 1: Permissionless `fundTaskFromPool` moves the entire reward pool onto any single live task, enabling pool capture and lockup (USER-RISK-DOS)
- **Severity:** Medium
- **Confidence:** High
- **Detected by:** attacker_review, rule_review
- **Description:** fundTaskFromPool is callable by anyone and unconditionally moves the whole rewardPool onto one chosen task's bounty, gated only by block.timestamp < revealEnd. Combined with open-posting (a stranger may post a task with up to a 10-minute window once the previous task has settled), an attacker can post a task they alone are positioned to score, redirect the entire converted BTCB reward pool onto it, and collect all of it as sole scorer — capturing prize money intended for the community. The same primitive also allows griefing: an attacker can move the whole pool onto a doomed live task, where it is only recoverable back into the pool after the 30-day CLAIM_WINDOW via reclaimBounty, delaying legitimate reward distribution.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol:fundTaskFromPool`
  - `src/AssayFlapVault.sol:collect`
  - `src/Tournament.sol:postTask`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted. This is the third round on this function and our two previous narrowings were both insufficient, which is worth saying plainly because each of them shipped with a passing test.

Round two moved the guard from revealEnd to commitEnd, so the pot is settled before the set of people dividing it is. Round three added `taskId == tournament.taskCount()`, so only the newest task can be funded. Your description defeats both in one step, and we reproduced it end to end: wait for the gap between epochs, post inside the open-post window, and the stranger's task IS the newest task the moment it exists. Both gates pass. The pool moves. The sole scorer takes it.

The mistake each time was fixing the example rather than the property. The property is that converted tax belongs to this project's epoch and must not be steerable by anyone else, and the line that says so is about WHO PUBLISHED the task, not which one it is:

    require(
        poster == curator || poster == _getGuardian(),
        unicode"Task is not ours / 任务非本方发布"
    );

`Tournament.taskGates` now returns the poster so the vault can ask. Open posting exists so a lost curator key cannot end the tournament — it was never a claim on the treasury. A stranger's task still runs, still scores, and still pays out whatever its poster escrowed; it simply cannot be handed the converted tax.

That also closes the griefing half: the doomed task an attacker would park the pool on is one they would have to publish, and they can no longer publish a fundable one.

Tested by running your sequence — warp into the gap, stranger posts, assert their task is both the newest and still in its commit window, then fund it — and confirmed by deleting the poster check and watching that test alone fail. The first version of that test was worthless, failing in setup with ERC20InsufficientBalance before it reached the assertion and failing identically with the guard removed; it funds the attacker now.


### Finding 2: Scheduled conversion uses a slippage floor fixed at scheduling time, weakening sandwich protection at execution (COM-MEV-SANDWICH)
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** rule_review
- **Description:** In the scheduled conversion path, minRewardOut is computed once in _arm() as quote(amount) * (10_000 - MAX_ENDOW_SLIPPAGE_BPS) / 10_000 and stored in scheduled[requestId]. The actual PancakeSwap swapExactETHForTokens executes later in trigger() -> _convertToPool() using that stored value. Because the Flap Trigger Service executes at an unpredictable, arbitrarily-later time, the stored floor can be stale relative to the market price at execution. If BTCB/BNB price moves favorably between arming and execution, the fixed floor tolerates far more than the intended 3% deviation, letting an MEV bot sandwich the swap and extract the difference between the fresh execution-time market output and the stale arm-time floor. The vault (whose BNB is trading tax destined for bounties) bears that loss.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol:_arm`
  - `src/AssayFlapVault.sol:trigger`
  - `src/AssayFlapVault.sol:_convertToPool`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted, and the reasoning about which direction is dangerous is right. `trigger` now prices a second floor at execution and hands the router the stricter of the two:

    uint256 fresh = (quote(s.bnbAmount) * (10_000 - MAX_ENDOW_SLIPPAGE_BPS)) / 10_000;
    uint256 floorNow = fresh > s.minRewardOut ? fresh : s.minRewardOut;

Deliberately not the fresh quote alone, which would be worse rather than better: it reads the same pair the swap is about to hit, so anyone able to move that pair in the same block would be setting our floor for us — the manipulation this guard exists to stop. Neither number is trustworthy by itself. The higher of the two is: a favourable move tightens the floor, and an unfavourable or manufactured one cannot loosen it below what was already committed to at arming.

This does not add a stall risk. An adverse move already reverted the swap against the stored floor before this change; taking the maximum only tightens the floor in the case where the fresh quote is achievable by construction.

Tested by moving the pair on a fork in the direction that makes the stored floor too loose, then asserting on the amountOutMin the router is HANDED via expectCall. Our first attempt asserted the amount that came back was at least the fresh floor, which is true whether or not the floor is enforced — nothing was extracting the difference, so the swap returned the full market amount either way, and it passed with the entire fix deleted. The test also asserts the pair actually moved, so it cannot quietly degrade into comparing two equal numbers.


### Finding 3: Self-arming conversion over-reserves by the scheduler fee, scheduling a swap larger than the vault's balance
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** In the self-arming path (trigger() → _arm(fee, 0)), _arm computes amount = freeTax() and reserves it, but the scheduler fee is paid out of the same native balance via requestTrigger{value: fee}. Because incoming == 0, nothing offsets the fee, so after arming reserved is set to the full pre-fee free tax while the actual balance is fee smaller. The scheduled bnbAmount therefore exceeds the vault's available balance by fee. When the trigger callback later executes _convertToPool(bnbAmount), router.swapExactETHForTokens{value: bnbAmount} attempts to send more native value than the contract holds and reverts, so the conversion cannot execute (and reserved stays inflated, zeroing freeTax() and blocking endow/withdrawUnconverted) until at least fee of additional tax arrives or a curator/guardian cancels the request.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol:_arm`
  - `src/AssayFlapVault.sol:trigger`
  - `src/AssayFlapVault.sol:_convertToPool`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Correct in every particular, and already fixed — the same defect was reported in the previous round and closed before this report was generated, so the code reviewed here is one commit behind. `_arm` nets the fee out of the convertible amount on the self-arming path, which `incoming == 0` identifies exactly because `triggerConversion` requires `msg.value >= fee`:

    if (incoming == 0) {
        if (amount <= fee) return 0;
        amount -= fee;
    }

Measured under a deliberate re-break: armed 2.4e15 against a balance of 2.2e15, over by exactly one scheduler fee.

Your account is more precise than ours was on one point and we have adopted it: the stall also zeroes freeTax() and therefore blocks endow and withdrawUnconverted, not merely the conversion cadence. That is the more serious half, since withdrawUnconverted is the path that does not require winning anything.

---

## Status

- `node tools/check-schema.mjs` reports every write method's schema matching its ABI type and
  every label bilingual.
- Both new guards were confirmed by breaking them and watching only their own test fail.
- No token has been launched on either chain.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x20b12D32f64c2e60a25E6E6828fF0AC39ee42d25` | `0x86EAE44Fd8e0c65C09D935521473d347f74EE7cc` |
| `Tournament` | `0xFAc3CfD91791431A9274f9a315374d02c09bF9d5` | `0xEF9661759Dd7aa8C49C647E01e18D132493a452B` |
| Tax token | not launched | not launched |
