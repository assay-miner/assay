# Vault self-check against the Flap specification

**Contract(s)**: `src/AssayFlapVault.sol`, `src/AssayFlapFactory.sol`
**Commit**: see `git log -1` at time of submission
**Date**: 2026-08-25

> This is the basic self-check step 3 of Flap's integration guide asks for, worked through the
> published rule set in `flap-vault-spec-checker`. It is not a substitute for the partner-firm
> audit required for the low-risk badge, and every finding below should be re-derived by whoever
> performs it.

## Executive Summary

`AssayFlapVault` turns a Flap taxed-V3 token's trading tax into BTCB prize money for a gas-optimisation tournament. Tax arrives as native BNB through `receive()`; the curator converts it to BTCB and books it behind a specific task; a miner the tournament has scored collects their share.

No Critical or High findings remain open. Every mandatory rule in the checker's list is satisfied. The two Medium findings are both disclosures rather than defects: one is the Guardian authority Rule 009 itself requires, and one is the residual sandwich exposure on a privileged swap that no in-contract bound fully removes.

Five spec violations were found and fixed during this pass and are listed under *Resolved during audit* rather than padded into the findings table.

## Scope

| File | Contract | Lines | Runtime |
|---|---|---|---|
| `src/AssayFlapVault.sol` | `AssayFlapVault is VaultBaseV2, ReentrancyGuard` | ~420 | 16,464 bytes |
| `src/AssayFlapFactory.sol` | `AssayFlapFactory is VaultFactoryBaseV2` | ~70 | 19,526 bytes |

Out of scope, and load-bearing: `src/Tournament.sol` supplies every score this vault pays against. It is covered by this project's own suite but is not a Flap vault and is not covered by these rules.

## Compliance Checklist

| Rule | Item | Result |
|---|---|---|
| 001 | Vault inherits `VaultBaseV2` | ✅ |
| 001 | `vaultUISchema()` implemented, `vaultType`/`description` non-empty | ✅ |
| 001 | Guardian reaches every privileged function | ✅ `endow` accepts curator or Guardian; emergency functions are Guardian-only |
| 001 | Guardian not revocable | ✅ address is fixed in `VaultBase._getGuardian()`; no setter exists |
| 001 | `revokeRole()` override | N/A — custom modifiers, not OZ `AccessControl` |
| 001 | No DOS via parameter manipulation | ✅ no mutable parameters exist; see L-03 for the liveness note |
| 002 | Factory inherits `VaultFactoryBaseV2` | ✅ |
| 002 | Commission fee recommendation | ⚠️ takes none — see L-02 |
| 003 | No privileged value extraction | ⚠️ see M-02 |
| 003 | Sandwich risk explicitly assessed | ✅ assessed below; bounded, not eliminated |
| 004 | Literal `require` strings, no custom errors | ✅ |
| 004 | All languages inline | ✅ every string is `en / zh` |
| 005 | `receive()` ≤ 1,000,000 gas | ✅ **measured 12,988** (1.3% of ceiling) |
| 005 | No loops / external calls / delegatecall in the `receive()` tree | ✅ body is one `emit` |
| 006 | Integration test coverage | ✅ `test/FlapSpec.t.sol` (13) + `test/RewardAsset.t.sol` (12), both forked |
| 007 | AI oracle | N/A — none |
| 008 | Trigger service | N/A — none |
| 009 | `emergencyWithdrawNative(address to)` verbatim | ✅ `onlyGuardian`, `nonReentrant`, full balance, event |
| 009 | `emergencyWithdrawToken(address token, address to)` verbatim | ✅ same |
| 009 | Emergency functions Guardian-only, no `amount`, caller-supplied `to` | ✅ |
| 009 | Auto-forward | N/A — not implemented (optional) |
| 010 | V3 ERC20-quote accounting | N/A — native quote, `vaultQuoteToken()` not implemented |

`vaultUISchema()` declares 8 methods. Field types are drawn only from the spec vocabulary and `decimals` is 18 for amounts and 0 for raw integers; both are asserted in `test_EveryFieldUsesTheSpecVocabulary`.

## Findings Summary

| Severity | Count | Description |
|----------|-------|-------------|
| Critical | 0     | — |
| High     | 0     | — |
| Medium   | 2     | Guardian authority over bounty funds; residual sandwich exposure on a privileged swap |
| Low      | 3     | Post-drain ledger drift; no commission; conversion liveness depends on curator |
| Info     | 3     | Bounded stats scan; base-contract errors; tournament dependency |

## Detailed Findings

### Medium

#### M-01: The Guardian can withdraw funds behind open bounties
**Severity**: Medium (centralization disclosure)
**Status**: Open — required by Rule 009
**File**: `src/AssayFlapVault.sol` — `emergencyWithdrawNative`, `emergencyWithdrawToken`

**Description.** Rule 009 makes these functions mandatory for a non-upgradeable vault, and specifies that they drain the *full* balance to a caller-supplied address. The reward token balance is not segregated from the amounts recorded in `bounty[]`, so the Guardian can remove BTCB a miner has already earned but not yet collected.

**Impact.** Every other path in this contract is arranged so value can only reach an address the tournament has scored. This is the single exception, and the holder of it is Flap's Guardian address, not the project's. A miner's unclaimed bounty is recoverable by Flap.

**Assessment.** This is not avoidable while remaining spec-compliant, and it does not add a new trust assumption: Flap's portal can already redirect where this token's tax is sent, so Flap is the protocol's trust anchor with or without these functions. The correct response is disclosure, not mitigation — the risk is stated in the vault's own NatSpec at the function, so anyone reading the verified source meets it there.

**Recommendation.** Keep as specified. Do not add an owner-callable variant.

#### M-02: A privileged caller can still sandwich the vault's own conversion
**Severity**: Medium
**Status**: Open — bounded, not eliminated
**File**: `src/AssayFlapVault.sol` — `endow`

**Description.** `endow` swaps native BNB for BTCB through PancakeSwap V2 with a caller-supplied `minRewardOut`. The caller is the curator or the Guardian. Before this audit the floor was unbounded, so a curator could pass `0`, sandwich the swap and keep the difference — value taken from the bounty, since the input is the token's trading tax. The floor is now required to be non-zero and no more than `MAX_ENDOW_SLIPPAGE_BPS` (300 = 3%) below the pool's spot price.

**Impact after the fix.** The naive case is closed. The residual case is not: an attacker who moves the pool in the same transaction also moves the `getAmountsOut` reading the bound is measured against, so a determined curator can still extract within a window they widen themselves. The size of that window is bounded by the tax accumulated since the last conversion.

**Proof of concept (residual).**
```solidity
// within one transaction, as curator:
//   1. buy BTCB, pushing the BNB→BTCB price against the vault
//   2. spot = quote(bnbAmount)      <- already depressed
//   3. endow(taskId, bnbAmount, spot * 0.97)  <- passes the bound
//   4. sell back, keeping the spread
```

**Recommendation.** Two options, both real:
1. Reference the floor against a TWAP rather than spot. Adds an oracle dependency and a staleness surface.
2. Remove the discretion: convert on a schedule, or let anyone call a permissionless `convert()` that only moves tax into an unassigned BTCB pool, with a separate `assign(taskId, amount)` that touches no market. This removes the privileged swap entirely at the cost of letting a griefer choose the moment of conversion.

Neither is free. The current bound plus disclosure is a defensible position for launch; option 2 is the right direction if the vault ever holds material size.

### Low

#### L-01: An emergency withdrawal leaves the ledger claiming coverage it no longer has
**Severity**: Low
**Status**: Open — detectable by design
**File**: `src/AssayFlapVault.sol` — `emergencyWithdrawToken`

**Description.** Rule 009 fixes these functions verbatim and they say nothing about accounting. After a token drain, `endowed`, `bounty[]` and the `committedBtcb` field of `stats()` all still report money behind tasks that is no longer held.

**Impact.** A UI reading `stats()` alone would display a funded bounty over an empty vault.

**Mitigation in place.** `solvent()` returns `reward.balanceOf(address(this)) >= endowed` and is declared in `vaultUISchema()` as an argument-free read, which is the one shape Flap's generic renderer always displays. `test_SolvencyGoesFalseAfterTheGuardianDrains` asserts the drift is visible.

**Recommendation.** Leave the emergency functions verbatim as the rule requires. Surface `solvent()` prominently in any custom UI.

#### L-02: The factory takes no commission
**Severity**: Low
**Status**: Open — requires a decision, per Rule 002
**File**: `src/AssayFlapFactory.sol`

**Description.** Rule 002 recommends a commission of 6% of `msg.value` for a tax rate ≤ 1%, and `msg.value * 6 / taxRateBps` above it. This factory takes none; 100% of the tax reaches bounties.

**Impact.** Strictly better for users than the recommendation, and worse for the vault developer, who earns nothing from the vault. Rule 002 asks for a justification when the recommendation is not followed.

**Justification offered.** The vault's purpose is to convert trading tax into verifiable work. A commission would reduce the prize for that work without funding any part of producing it. If a commission is wanted later it must be introduced at deployment of a new factory — this one has no parameter to change, which is also what makes it non-DOSable under Rule 001.

#### L-03: Conversion depends on the curator or the Guardian acting
**Severity**: Low
**Status**: Open — by design
**File**: `src/AssayFlapVault.sol` — `endow`

**Description.** Tax accumulates as native BNB and only becomes a bounty when `endow` is called. If neither the curator nor the Guardian calls it, tax sits unconverted indefinitely.

**Impact.** No user funds are at risk — nothing is owed to anyone out of unconverted tax — but the vault's stated purpose stalls. `stats()` reports `unassignedBnb`, so the condition is visible.

**Recommendation.** The permissionless-convert option in M-02 also resolves this.

### Info

- **I-01**: `stats().openTasks` scans only the most recent `STATS_SCAN = 64` tasks. Beyond that it understates. Deliberate: the view is polled by a UI and an unbounded walk would get slower for exactly the vaults doing well. `tasks` and every amount are exact.
- **I-02**: `VaultBaseV2` and `VaultFactoryBaseV2` declare custom errors (`UnsupportedChain`, `OnlyVaultPortal`, …). These are Flap's own base contracts, unmodified, and outside UI-01's scope. Every revert authored in the two contracts audited here is a literal bilingual string. The tournament contracts behind them still use custom errors; they are not Flap vaults, their reverts do not surface in Flap's UI, and changing them would cost the type safety their own tests rely on.
- **I-03**: `collectable` and `collect` read `tournament.submissions` and `tournament.tasks`. The tournament is deployed alongside the vault and its correctness is load-bearing for every payout. It is immutable in the vault (`Tournament public immutable tournament`) and cannot be repointed.

## Resolved during audit

Found by working the checker's list against the contracts, and fixed before this report:

1. **UI-01 violation** — all eight custom errors in the vault and both in the factory were replaced with `require()` and literal `en / zh` strings.
2. **Rule 009 violation** — `emergencyWithdrawNative` and `emergencyWithdrawToken` were absent entirely; added verbatim to the rule's reference implementation, with `ReentrancyGuard`.
3. **Rule 003 violation** — `endow` accepted `minRewardOut = 0` from a privileged caller. Now bounded to 3% below spot; see M-02 for what remains.
4. **Rule 006 gaps** — no test covered the `receive()` gas budget, Guardian access, the factory's portal guard, `vaultDataSchema()`, or `description()` moving with state. `test/FlapSpec.t.sol` covers all of them.
5. **Reentrancy hardening** — `endow`, `sponsor` and `collect` are now `nonReentrant`. `sponsor` in particular pulled tokens before updating state; the reward token is immutable BTCB so no callback exists today, but the ordering was wrong on its own terms.

## Centralization Analysis

### Admin controls
There is no owner, no admin role and no mutable parameter. Two addresses have capability:

| Actor | Can | Cannot |
|---|---|---|
| Curator (token creator, fixed at creation) | Convert tax and place it behind a task | Withdraw anything; change any parameter; take money back out of a task |
| Guardian (Flap, fixed in `VaultBase`) | Everything the curator can, plus drain the vault | Be replaced or revoked |
| Anyone | `sponsor` a bounty; `collect` a scored share | — |

### Upgrade mechanisms
None. The vault is deployed directly by the factory, not behind a proxy. All venue addresses (reward token, router) are `immutable` and resolved from `block.chainid` at construction, so no caller can name the contracts the vault sends value through.

### Emergency functions
As specified by Rule 009 and discussed in M-01.

### Decentralization recommendations
The curator's discretion over *when* to convert and *which task* receives it is the main centralization surface after the Guardian. Splitting conversion from assignment (M-02, option 2) would reduce it to "which task", which is the part that arguably should stay with the party posting the work.

## Gas Optimization Recommendations

- `receive()` is 12,988 gas — one event, nothing else. No action.
- `stats()` accumulates `totalPaid`/`payouts` on write rather than summing on read, which is what keeps a polled view O(1) in the amounts. The only unbounded-ish part is the 64-task scan, already bounded.
- `collectable` performs two external view calls into the tournament. It is called once inside `collect` and once by the UI; caching within `collect` would save a little and complicate the read path. Not worth it.

## Best Practices and Code Quality

### Positive observations
- No caller-supplied protocol addresses anywhere; the router and reward token are immutable and chain-derived.
- `endow` books the amount that actually arrived from the swap, not the quoted amount.
- `_requireTask` prevents money being placed behind a task id that does not exist, which in a vault with no sweep would be a permanent loss with every ledger still balancing.
- Every claim in the schema is asserted against the real ABI by `test/FlapRender.t.sol`, including that each named method resolves and returns the declared number of words.
- The full protocol is exercised end to end against a fork by `tools/rehearse.sh`, including the miner client.

### Areas for improvement
- The residual sandwich window in M-02.
- `collect` reverts rather than returning zero when there is nothing to take. That is correct for a transaction but means a UI must read `collectable` first to avoid offering a button that cannot work; the shipped UI does.

## Testing and Verification Recommendations

103 tests pass across 12 suites, of which six are forked against real BSC state (four against mainnet, two against testnet). Before mainnet:

1. Run `tools/rehearse.sh` against a mainnet fork as well as testnet — the reward venue differs by chain and only the testnet path has been walked end to end.
2. Deploy to BNB testnet and exercise `endow` and `collect` through `testnet.flap.sh` rather than only through the local preview.
3. Have the partner firm review M-02 specifically; it is the finding where an in-contract fix has real trade-offs and an outside opinion is worth the most.

## Conclusion

Both contracts satisfy every mandatory rule in the Flap vault specification. No Critical or High findings are open. The Medium findings are the Guardian authority the specification itself mandates, and a residual sandwich exposure that is bounded but not closed; both are disclosed in the source rather than only here. The vault is, in my assessment, ready for testnet deployment and for submission to a partner audit.

## Disclaimer

This self-check does not guarantee the absence of bugs or vulnerabilities. Smart contracts should undergo multiple audits and extensive testing before mainnet deployment. It follows Flap's published rule set and reflects the contracts at the commit noted above; any change after that point invalidates it.
