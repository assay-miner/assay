# Flap Vault Interaction Risk Report

Generated: 2026-09-03 17:08:55 UTC

## Vault Security Rating
**Low**

Project: ASSAY (`AssayFlapVault`)

Finding 2 is accepted and fixed by removing the mechanism that caused it rather than narrowing
it. Finding 1 is acknowledged: the mechanism is real, we looked for a fix, and neither of the
two obvious ones survives inspection — both are measured in the response below.

---

## Risk Findings

### Finding 1: Open-post fallback can be monopolised by a griefer via latestRevealEnd high-water mark
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** During a curator/Guardian outage, any address may post tasks through Tournament.postTask's open-window branch. Open posts are gated by `require(block.timestamp >= latestRevealEnd)`, and every post raises `latestRevealEnd` (a monotonic high-water mark) by up to OPEN_POST_MAX_SPAN. A griefer who posts a trivial (pot=0) task taking the boundary block each cycle keeps `latestRevealEnd` permanently ahead of `block.timestamp`, winning the posting race repeatedly and preventing other honest strangers from posting fallback tasks. The fund-locking aspect was mitigated by moving the vault's withdrawal gate to `latestCuratedRevealEnd`, but the open-poster-vs-open-poster monopoly on the fallback path remains.
- **Vulnerable Code:**
  - `src/Tournament.sol: postTask (open-window branch, latestRevealEnd gate)`

> **Status:** `[ ]` TP　`[ ]` FP　`[ ]` By Design　`[x]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** The mechanism is exactly as described, and we looked for a fix before deciding not to ship one. Two look obvious and neither survives contact.

**Requiring a non-zero pot** does not raise the cost, because the capital comes back almost free: `reclaim` pays out the instant `revealEnd` passes if `totalScore == 0`, skipping the 30-day `CLAIM_WINDOW` entirely — and nobody scores a task posted only to occupy a slot, since real miners are not going to spend gas competing for it. `test_ANonZeroPotIsNotARealCostBecauseItComesRightBack` posts with a real pot and reclaims it in the same block the window closes, whole and immediately spendable on the next post.

**Rejecting a repeat poster** does not survive a second address. Any per-address cooldown is a one-line workaround for anyone willing to hold two EOAs, and EOAs are free. This contract has no way to know that two addresses are the same actor, and inventing one (identity, staking, a whitelist) is a different, much larger design than this finding is asking for.

`test_AGrieferHoldsTheOpenSlotAgainstAnHonestStranger` measures the actual denial: a griefer posting a zero-pot task each cycle, taking the maximum span every time, keeps a second stranger — funded and ready to post a real task — locked out for three consecutive cycles, which is bounded only by how long the griefer keeps paying gas. `test_AnHonestStrangerPostsFineWhenNobodyIsHoldingTheSlot` is the control: the same honest stranger, absent the griefer, posts without incident the moment the window opens — confirming the denial is the occupation and not a mistake in how the test builds its call.

**What stays out of reach regardless.** `fundTaskFromPool` has required the poster be the curator or the Guardian since an earlier round, so nothing a griefer posts can ever be handed the converted tax. Monopolising this path denies other strangers a chance to post a fallback task; it is not a path to the treasury, and it was never one — that finding is already closed. What remains is availability, not funds: with the curator and Guardian both gone, the tournament cannot be revived by a stranger's goodwill if a griefer wants it kept dead, but nothing already in the vault or already scored is at risk, and `withdrawUnconverted` does not wait on this mark at all any more.

We are not aware of an on-chain fix that closes this without either a cost the attacker doesn't actually pay or an identity assumption this contract does not make. Acknowledged rather than fixed, and measured rather than left as a paragraph nobody re-checks.


### Finding 2: fundTaskFromPool permits epoch-to-bounty misallocation via permissionless early funding
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** fundTaskFromPool is permissionless, one-shot per task (pooledInto), and moves the ENTIRE current rewardPool onto the newest task. The design intends each epoch's converted tax to fund that epoch's task ('an epoch converts what it accrued and its task takes what that bought'). Because anyone can call it the instant the pool becomes non-zero, an actor can fund the current task with only the first conversion slice of the epoch, setting pooledInto=true, so all further same-epoch conversions cannot be added to that task and instead roll forward into the next epoch's task.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: fundTaskFromPool`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted, and fixed by removing the one-shot flag rather than gating who or when may call it — the flag was never load-bearing for anything the rest of the contract depends on, and dropping it closes the finding directly instead of narrowing it.

`pooledInto` is gone. A task may now be funded more than once while it is still open:

    function fundTaskFromPool(uint256 taskId) external nonReentrant returns (uint256 amount) {
        _requireTask(taskId);
        require(taskId == tournament.taskCount(), unicode"Not the current task / 非当前任务");
        (uint64 commitEnd,,, address poster) = tournament.taskGates(taskId);
        require(block.timestamp < commitEnd, unicode"Commitment closed / 承诺已截止");
        require(poster == curator || poster == _getGuardian(), unicode"Task is not ours / 任务非本方发布");
        amount = rewardPool;
        require(amount > 0, unicode"Pool is empty / 池中无资金");
        rewardPool -= amount;
        bounty[taskId] += amount;
        emit TaskFunded(taskId, amount);
    }

This is safe without the flag because the pool is swept to zero on every successful call: a second call before new money arrives has nothing to move and reverts on `amount > 0` rather than double-counting anything. The flag was solving a problem the sweep semantics already solved, at the cost of the exact misallocation this finding describes.

Removing it also answers a question from an earlier round without reopening it: `pooledInto` was introduced so `sponsor`-ed dust couldn't make `bounty[taskId] == 0` look like "already funded" and permanently block this function. That protection did not depend on `pooledInto` specifically — it depends on this function reading `rewardPool`, not `bounty[taskId]` — so it is intact with the flag gone; `test_DustSponsorshipCannotBlockPoolFunding` still passes unmodified.

Tested directly against the scenario described: `test_AnEarlySmallCallDoesNotCapWhatTheTaskCanStillReceive` funds a task with a tiny early conversion, adds a much larger one while the task is still open, and confirms both land on the same bounty rather than the second rolling forward. `test_ATaskCanBeFundedMoreThanOnceWhileItIsStillOpen` and `test_CallingAgainOnAnEmptyPoolChangesNothing` cover the two shapes a repeat call can take. Confirmed by reintroducing the old one-shot flag under a different name and watching all three fail while the rest of the suite does not.

---

## Status

- Finding 2's guards were confirmed by reintroducing the removed flag and watching exactly the
  tests that describe it fail.
- No token has been launched on either chain.
- **BSC mainnet carries the current code; BSC testnet is behind.** The testnet deploy failed for
  gas — the public BNB testnet faucet is out of funds — so that address still runs an earlier
  revision. The bytecode check in our packaging step is against mainnet and it passes.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x6b220DACd22467e837249344399A5d52951Ae264` | `0xF062f9B72778294819486c68CbceAcbea8F9078a` |
| `Tournament` | `0x2d14990a90640435CdbE13BA80e9c57e81d9c5dd` | `0x5c9e36e588859516007e06de145Bde6f92bF883A` |
| Tax token | not launched | not launched |
