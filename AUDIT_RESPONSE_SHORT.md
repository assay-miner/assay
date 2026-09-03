# Flap Vault Interaction Risk Report

Generated: 2026-09-03 09:50:33 UTC

## Vault Security Rating
**Low**

Project: ASSAY (`AssayFlapVault`)

Accepted. This was fixed two rounds ago, so the snapshot reviewed here is behind the tree; the
response gives the current code and a command that checks it in the archive.

---

## Risk Findings

### Finding 1: Manual triggerConversion is bound by FEE_COVER_MULTIPLE contrary to its documented intent
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** In AssayFlapVault._arm the guard `if (amount <= fee * FEE_COVER_MULTIPLE) return 0;` is placed outside the `if (incoming == 0)` block, so it applies to BOTH the self-arming path (incoming == 0) and the manual path invoked through triggerConversion (incoming == msg.value > 0). The in-code comment states the manual path 'pays its own fee and is not bound by this; only the arming that spends tax is.' The actual behavior is that a manual caller who pays their own scheduler fee is still refused whenever the accrued convertible tax is not strictly greater than 10 * fee, causing triggerConversion to revert with 'Nothing to convert'. Consequently a user cannot manually convert (or manually restart a stalled conversion cadence for) any tax amount at or below ten scheduler fees, even though they are paying the fee themselves, so such tax remains unconverted longer than the design intends.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol:_arm (the `if (amount <= fee * FEE_COVER_MULTIPLE) return 0;` line, applied to the manual triggerConversion path)`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted, and already fixed — this was closed two rounds ago, so the snapshot reviewed here is behind the tree. The guard now sits inside the block, which is where the comment beside it always said it belonged:

    if (incoming == 0) {
        // The fee leaves this balance, and this balance is tax.
        if (amount <= fee) return 0;
        amount -= fee;

        // Worth doing, not merely possible — and only here.
        if (amount <= fee * FEE_COVER_MULTIPLE) return 0;
    }

Verifiable in the archive accompanying this response:

    awk '/if \(incoming == 0\)/,/^        }/' src/AssayFlapVault.sol | grep -c FEE_COVER_MULTIPLE   # 1
    grep -c 'FEE_COVER_MULTIPLE' src/AssayFlapVault.sol                                              # 2, the constant and that one use

Your reading of why is the one we came round to, and it is worth recording that we first answered this the wrong way. An earlier round of yours raised the same contradiction and we resolved it by rewriting the comment to match the code, arguing that every conversion moves BNB from the side that returns to the curator into the side only a scoring miner can take out, and that `triggerConversion` is permissionless. That argument is true and it is not this guard's argument. The floor exists because the self-arming path buys the scheduler out of tax; a caller who supplies the fee spends none of the vault's, so the premise never reached them.

What decided it was the consequence you name here: `triggerConversion` is the restart for a stalled cadence, and a floor that refuses it whenever free tax is under ten fees refuses it in exactly the low-activity state a stall comes from. A guard that disables the recovery path under the conditions that produce the failure is not a conservative guard.

Residual, stated rather than buried: anyone may now force a small conversion at their own expense, moving that BNB from the withdrawable side to the side that must be won back. The caller pays the fee every time, the impact and slippage guards still refuse sizes the pair cannot take, and the resulting BTCB still funds this project's own tasks. We prefer that to a recovery path that does not work when it is needed.

Both directions are covered by tests — a window under the floor converts when the caller pays the fee, and the same window still does not arm itself out of tax — and both were confirmed by moving the guard back outside the block, where the manual test fails with "Nothing to convert / 无可兑换" and the self-arming one still passes.

---

## Status

- 228 tests across 32 suites.
- Every guard added across these rounds was confirmed by breaking it and watching only its own
  test fail.
- No token has been launched on either chain.
- **BSC mainnet carries the current code; BSC testnet is behind.** The testnet deploy failed for
  gas — the public BNB testnet faucet is out of funds — so that address still runs an earlier
  revision. The bytecode check in our packaging step is against mainnet and it passes. Flagged
  rather than left for a reviewer to find.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x6b220DACd22467e837249344399A5d52951Ae264` | `0xCB30071bfF091859Ca9f4e4f3fBe68F8bA40e18F` |
| `Tournament` | `0x2d14990a90640435CdbE13BA80e9c57e81d9c5dd` | `0x44A97Dc7E55DA073fCD091542Edff9A43263557A` |
| Tax token | not launched | not launched |
