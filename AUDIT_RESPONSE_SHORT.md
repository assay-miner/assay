# Flap Vault Interaction Risk Report

Generated: 2026-09-02 06:23:02 UTC

## Vault Security Rating
**Medium**

Project: ASSAY (`AssayFlapVault`)

Both findings accepted. They are the same defect seen from two sides, and we answered it the
wrong way round last round — the response says why the direction changed, and why the earlier
answer never reached the file at all.

---

## Risk Findings

### Finding 1: FEE_COVER_MULTIPLE gate applied to the manual conversion path, contradicting its documented scope
- **Severity:** Medium
- **Confidence:** High
- **Detected by:** doc_review
- **Description:** The NatSpec on the amount <= fee * FEE_COVER_MULTIPLE check in _arm states: "The manual path pays its own fee and is not bound by this; only the arming that spends tax is." This documents that the FEE_COVER_MULTIPLE minimum-window gate should apply ONLY to the self-arming path (where incoming == 0 and the fee is paid out of accumulated tax), and NOT to the manual triggerConversion path (where the caller supplies the fee via msg.value). However, the actual check if (amount <= fee * FEE_COVER_MULTIPLE) return 0; sits outside the if (incoming == 0) block, so it is applied unconditionally to BOTH the manual and self-arming paths.
- **Vulnerable Code:**
  - `AssayFlapVault._arm`
  - `AssayFlapVault.triggerConversion`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** The check now sits inside `if (incoming == 0)`, where the comment always said it belonged:

    if (incoming == 0) {
        if (amount <= fee) return 0;
        amount -= fee;
        if (amount <= fee * FEE_COVER_MULTIPLE) return 0;
    }

We answered this once before and got it the wrong way round: last round we kept the code and rewrote
the comment to say the floor binds both paths, on the grounds that every conversion moves BNB from
the side that returns to the curator into the side only a scoring miner can take out, and that
`triggerConversion` is permissionless. That reasoning is real but it is not this guard's reasoning.
This floor exists because the self-arming path buys the scheduler out of tax — a window worth barely
more than the fee costs almost as much to convert as it converts, and at one epoch every five
minutes that is 288 fees a day against a vault nobody is trading. A caller who supplies the fee
spends none of the vault's tax, so the premise does not reach them.

The second argument decided it. `triggerConversion` is the restart when the self-arming chain has
stopped, and refusing it whenever free tax is under ten fees refused it in exactly the low-activity
case where a stall is most likely and the manual kick-start is most needed. A guard that disables
the recovery path under the conditions that produce the failure is not a conservative guard.

**Residual we are accepting rather than hiding:** anyone may now force a small conversion at their
own expense, moving that BNB from the withdrawable side to the side that must be won back. It is
bounded — the caller pays the fee every time, the impact and slippage guards still refuse sizes the
pair cannot take, and the resulting BTCB still funds this project's own tasks. We prefer that to a
recovery path that does not work when it is needed.

Both directions are tested: a window under the floor converts when the caller pays the fee, and the
same window still does not arm itself. Confirmed by moving the check back outside the block, where
the first test fails with "Nothing to convert / 无可兑换" and the second still passes.

One more thing belongs in this answer, because it is the reason you are seeing this finding twice.
We reported this same contradiction as fixed in the previous round and it was not. The edit was one
of several in a script that applied every replacement and wrote the file once at the end; a later
replacement failed its anchor, the exception reached the top before the write, and nothing landed.
We read the absence of an error from the earlier steps as success and said so. A second comment fix
in that same batch — the `curator` NatSpec claiming it may endow — was lost the same way and is
also corrected now. Edits are written and read back one at a time here from now on.


### Finding 2: FEE_COVER_MULTIPLE gate wrongly applied to the manual conversion path, blocking small manual conversions
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** In AssayFlapVault._arm the guard if (amount <= fee * FEE_COVER_MULTIPLE) return 0; is placed outside the if (incoming == 0) block, so it is enforced on both the self-arming path (which pays the scheduler fee out of vault tax) and the manual triggerConversion path (where the caller pays the fee out of their own msg.value). The adjacent comment explicitly states this economics gate should bind only the self-arming path ("The manual path pays its own fee and is not bound by this; only the arming that spends tax is"). As a result, a manual triggerConversion call reverts with "Nothing to convert" whenever the free tax to be converted is less than or equal to 10× the scheduler fee, even though the caller is fully subsidizing the fee. This defeats the documented purpose of triggerConversion as a manual restart/recovery path precisely in low-activity scenarios (small accrued tax), where a stall is most likely and the manual kick-start is most needed.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: _arm (if (amount <= fee * FEE_COVER_MULTIPLE) return 0;)`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** The check now sits inside `if (incoming == 0)`, where the comment always said it belonged:

    if (incoming == 0) {
        if (amount <= fee) return 0;
        amount -= fee;
        if (amount <= fee * FEE_COVER_MULTIPLE) return 0;
    }

We answered this once before and got it the wrong way round: last round we kept the code and rewrote
the comment to say the floor binds both paths, on the grounds that every conversion moves BNB from
the side that returns to the curator into the side only a scoring miner can take out, and that
`triggerConversion` is permissionless. That reasoning is real but it is not this guard's reasoning.
This floor exists because the self-arming path buys the scheduler out of tax — a window worth barely
more than the fee costs almost as much to convert as it converts, and at one epoch every five
minutes that is 288 fees a day against a vault nobody is trading. A caller who supplies the fee
spends none of the vault's tax, so the premise does not reach them.

The second argument decided it. `triggerConversion` is the restart when the self-arming chain has
stopped, and refusing it whenever free tax is under ten fees refused it in exactly the low-activity
case where a stall is most likely and the manual kick-start is most needed. A guard that disables
the recovery path under the conditions that produce the failure is not a conservative guard.

**Residual we are accepting rather than hiding:** anyone may now force a small conversion at their
own expense, moving that BNB from the withdrawable side to the side that must be won back. It is
bounded — the caller pays the fee every time, the impact and slippage guards still refuse sizes the
pair cannot take, and the resulting BTCB still funds this project's own tasks. We prefer that to a
recovery path that does not work when it is needed.

Both directions are tested: a window under the floor converts when the caller pays the fee, and the
same window still does not arm itself. Confirmed by moving the check back outside the block, where
the first test fails with "Nothing to convert / 无可兑换" and the second still passes.

Your framing is what changed our answer. We had weighed this as a documentation mismatch and picked
the wrong half to correct; reading it as a liveness property — the recovery path must work under the
conditions that cause the failure — makes the direction obvious.

---

## Status

- Both new tests were confirmed by breaking the guard and watching only the right one fail.
- The `curator` NatSpec correction lost in the previous round's batch has also landed.
- No token has been launched on either chain.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0xEF9661759Dd7aa8C49C647E01e18D132493a452B` | `0x5389c9b7B05854C1e0b7b0b689706706D3b74f17` |
| `Tournament` | `0xcd0399c096C28C4aDc765b424b0DCb2aFE5257BC` | `0x09c4105bBB90C2EFf7E96dE1729344a1EfA4f48C` |
| Tax token | not launched | not launched |
