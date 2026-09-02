# Flap Vault Interaction Risk Report

Generated: 2026-09-02 09:11:35 UTC

## Vault Security Rating
**High**

Project: ASSAY (`AssayFlapVault`)

All three findings accepted. Finding 2 was fixed in the round before this report was generated.
Findings 1 and 3 are opposite sides of one question — who may stall whom — and both are answered
by asking who is acting rather than by narrowing what they may do.

---

## Risk Findings

### Finding 1: Curator can prevent trading tax from becoming prize money and redirect it to itself (USER-RISK-UNFAIR-PARAMS)
- **Severity:** High
- **Confidence:** Low
- **Detected by:** rule_review
- **Description:** The vault's stated purpose is to convert a token's BNB trading tax into BTCB prizes for tournament miners. However, the curator (the token creator, which is explicitly NOT the trusted guardian) controls two functions that together let it starve the prize pool and pocket the tax. Async conversions scheduled via triggerConversion/_arm can be unilaterally aborted by the curator through cancelConversion (which frees `reserved` and leaves the BNB unconverted), and the only atomic conversion path (endow) is guardian-only, so the curator can keep tax from ever becoming BTCB. Once a task's reveal window has passed (`block.timestamp >= tournament.latestRevealEnd()`), withdrawUnconverted sends all remaining unconverted native tax to the fixed `curator` address. A curator that opens tournaments (attracting miners who lock tax-token stake and expend optimisation effort), cancels every scheduled conversion so no `rewardPool`/`bounty` ever forms, and then calls withdrawUnconverted after settlement, receives the tax while participating miners earn zero BTCB despite performing the work the bounty was advertised for.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol:cancelConversion`
  - `src/AssayFlapVault.sol:withdrawUnconverted`
  - `src/AssayFlapVault.sol:endow`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted. The chain you describe is exact, and the curator should never have held that lever: cancelling frees the BNB back into `freeTax()`, and `freeTax()` is precisely what `withdrawUnconverted` pays to the curator. Cancel each conversion as it is armed and no BTCB ever forms, while the tournament goes on advertising prizes and miners go on staking and optimising. A vault whose whole purpose is turning tax into prizes cannot leave that path open.

The curator can no longer cancel at all. What remains is the reason cancellation was added — a request that can no longer succeed — expressed as a condition rather than a judgement:

    require(
        msg.sender == _getGuardian()
            || block.timestamp > uint256(s.executeAfter) + CANCEL_GRACE,
        unicode"Not cancellable yet / 尚不可取消"
    );

The Guardian may act at any time. Anyone may clear a request the scheduler has plainly abandoned, one hour past the moment it was due. So genuinely dead requests never trap `reserved`, and nobody has to be trusted to notice — while a live conversion cannot be aborted by the party that profits from aborting it. `ScheduledEndow` carries `executeAfter` for this; the two `uint128` fields narrowed to `uint96` so the struct still occupies one slot.

Both halves are tested, and confirmed by restoring `msg.sender == curator` to the guard and watching the curator test fail while the past-due one still passes.

**What we have not changed, and why:** unconverted tax from windows nobody mined still goes to the curator. That is the design — an epoch with no participants should not strand its tax forever — and it is now reachable only by waiting, not by intervening. The difference this fix makes is that the curator can no longer *manufacture* an empty window.


### Finding 2: FEE_COVER_MULTIPLE incorrectly gates the manual triggerConversion path, contradicting its documented intent and blocking small manual conversions
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** In AssayFlapVault._arm the check `if (amount <= fee * FEE_COVER_MULTIPLE) return 0;` is placed after the `if (incoming == 0)` self-arm block, so it applies to BOTH the self-arming path and the manual `triggerConversion` path. The in-line comment states the opposite: "The manual path pays its own fee and is not bound by this; only the arming that spends tax is." Because the manual path IS bound by it, any manual `triggerConversion` where the free tax is `<= fee * 10` returns requestId 0, which then triggers `require(requestId != 0, "Nothing to convert")` and reverts. The manual call is documented as the recovery path that restarts the self-arming cadence when the scheduler stalls; when the accumulated tax is small (which is exactly the stalled/low-volume state), that recovery path is unavailable, and only the Guardian's `endow` can convert.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: _arm (the `if (amount <= fee * FEE_COVER_MULTIPLE) return 0;` line applies to both paths)`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted, and fixed in the round before this report was generated, so the code reviewed here is one commit behind. The check now sits inside `if (incoming == 0)`, where the comment always said it belonged.

The floor exists because the self-arming path buys the scheduler out of tax; a caller who supplies the fee spends none of the vault's, so the premise never reached them. Your second argument is the one that decided it for us: `triggerConversion` is the restart when the self-arming chain has stopped, and refusing it whenever free tax is under ten fees refused it in exactly the low-activity case where a stall is most likely.

Residual, stated rather than hidden: anyone may now force a small conversion at their own expense, moving that BNB from the withdrawable side to the side that must be won back. The caller pays every time, the impact and slippage guards still refuse sizes the pair cannot take, and the resulting BTCB still funds this project's own tasks.

Both directions are tested — a window under the floor converts when the caller pays the fee, and the same window still does not arm itself.


### Finding 3: withdrawUnconverted can be indefinitely blocked by permissionless task posting keeping latestRevealEnd in the future
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** AssayFlapVault.withdrawUnconverted gates solely on `block.timestamp >= tournament.latestRevealEnd()` with no curator/Guardian override. `latestRevealEnd` is a monotonic high-water mark that any stranger can advance by posting a task (postTask open-post window, or via the public TaskGenerator.generateAndPost). Because a stranger can only post once `block.timestamp >= latestRevealEnd`, the exact block in which withdrawUnconverted becomes callable is also the block in which a new open-post task can be created. An attacker who front-runs the boundary each cycle (a fresh 10-minute-span task every ~10 minutes) keeps `latestRevealEnd` perpetually in the future, so the project can never satisfy the `>= latestRevealEnd` condition and can never reclaim unconverted BNB tax from empty windows.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: withdrawUnconverted (require block.timestamp >= tournament.latestRevealEnd())`
  - `src/Tournament.sol: postTask / latestRevealEnd high-water mark`
  - `src/TaskGenerator.sol: generateAndPost (permissionless posting)`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted. We had seen half of this — `OPEN_POST_MAX_SPAN` caps a single open post at ten minutes precisely so one post cannot freeze the tax for thirty days — and the comment above that constant says so. What we missed is that the cap bounds one post and nothing bounds repetition. Taking the boundary block every cycle is exactly as effective as one long post, and cheaper to sustain.

`Tournament` now keeps a second high-water mark advanced only by posts from the curator or the Guardian, and the withdrawal waits on that one:

    uint64 public latestCuratedRevealEnd;

A stranger's task cannot be funded from the reward pool — that gate was added in the previous round — so unconverted tax is not holding anything up for it, and it has no claim on delaying a withdrawal. Our own open task still does, which is what the gate was for.

Tested by warping past our own task's reveal, letting a stranger post the longest open window they may, and then calling `withdrawUnconverted` and asserting it succeeds and the BNB reaches the curator. Confirmed by pointing the gate back at `latestRevealEnd`, where it fails with "Epoch open / 本期未结束".

The first version of that test compared the two marks against each other and passed with the vault still reading the wrong one — it was testing `Tournament` rather than the gate. It asserts on the withdrawal itself now.

---

## Status

- Every new guard was confirmed by breaking it and watching only its own test fail.
- No token has been launched on either chain.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x68c2656B23329d4Ceee87d39a1038EA5aAdAa222` | `0x3B0da8368e01b516703E65Ce9Ba9be9d1B327341` |
| `Tournament` | `0xe432Ad772b2498631f7e1806BD0D33c35b184233` | `0x57e19122B5136E4808A6351B20286D07a67Fb522` |
| Tax token | not launched | not launched |
