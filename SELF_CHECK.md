# Vault self-check against the Flap specification

**Contract(s)**: `src/AssayFlapVault.sol`, `src/AssayFlapFactory.sol`
**Commit**: see `git log -1` at time of submission
**Date**: 2026-08-25

> This is the basic self-check step 3 of Flap's integration guide asks for, worked through the
> published rule set in `flap-vault-spec-checker`. It is not a substitute for the partner-firm
> audit required for the low-risk badge, and every finding below should be re-derived by whoever
> performs it.

## Executive Summary

`AssayFlapVault` turns a Flap taxed-V3 token's trading tax into BTCB prize money for a gas-optimisation tournament. Tax arrives as native BNB through `receive()`. Anyone may schedule its conversion to BTCB — the
vault sizes it, prices it and hands it to Flap's Trigger Service, and the callback arms the next
epoch, so the cadence needs nobody to run it. The BTCB lands in a pool belonging to no task, and
anyone may hand a task the whole pool. A miner the tournament has scored collects their share, and
anything nobody claims goes back to the pool.

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
| 003 | No privileged value extraction | ✅ the curator no longer submits the swap they price — see M-02 |
| 003 | Sandwich risk explicitly assessed | ✅ assessed below and removed via the Trigger Service |
| 004 | Literal `require` strings, no custom errors | ✅ |
| 004 | All languages inline | ✅ every string is `en / zh` |
| 005 | `receive()` ≤ 1,000,000 gas | ✅ **1,832 gas** in the body; 12,988 including the caller's CALL and value transfer. Either figure is a rounding error against the ceiling. |
| 005 | No loops / external calls / delegatecall in the `receive()` tree | ✅ body is one `emit` |
| 006 | Integration test coverage | ✅ the whole suite ships in the archive, which measures and states its own counts |
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
| Medium   | 1     | Guardian authority over bounty funds (Rule 009 requires it) |
| Low      | 3     | Post-drain ledger drift; no commission; conversion liveness depends on curator |
| Info     | 6     | Bounded stats scan; base-contract errors; tournament dependency; two custody gaps found and fixed during this pass; one stated asset assumption |

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

#### M-02: The privileged swap was sandwichable by the party who priced it — resolved
**Severity**: Medium
**Status**: Resolved — the conversion is no longer submitted by the party that prices it
**File**: `src/AssayFlapVault.sol` — `triggerConversion`, `trigger`, `endow`

**What it was.** `endow` let the curator price a swap and broadcast it in the same transaction.
The slippage floor was bounded to 3% below spot, which closed the case of a caller simply
declaring any price acceptable, and closed nothing else: a floor derived from spot cannot bound
an actor who moves spot in the same transaction. An earlier revision of this report said so and
asked Flap for an opinion on the two fixes we could see — a TWAP reference, or splitting
conversion from assignment.

**What resolved it.** Flap's own Trigger Service, suggested during pre-audit review, and better
than either. The problem was never really the arithmetic; it was that one party priced, submitted
and could surround the swap. Splitting those apart removes it:

- `triggerConversion()` takes nothing and is open to anybody. It sizes the conversion from the
  window's accrual, bounds the floor against spot at that moment, and pays the scheduler's fee. It
  does not touch the pool.
- `trigger(requestId)` is the callback. The transaction that swaps is submitted by Flap's backend
  through an MEV-protected path, at a time the curator cannot predict. There is no ordering left
  for them to arrange around, and nothing in the public mempool for anyone else to race.
- `endow` is now **Guardian-only**, kept for the case where the scheduler itself is unavailable.
  Leaving it open to the curator would have left the original path intact and fixed nothing.

The floor is bounded where it is set rather than where it executes. Bounding it at execution
would re-derive it from a pool the curator could have moved beforehand; bounding it at scheduling
ties it to the price when it was set, and execution simply honours it. If the market moves past
the floor in the meantime the swap reverts, the request is marked FAILED, and anyone may
`retryTrigger` it — a conversion that would now be bad does not quietly happen.

**The failure modes that come with the integration**, each handled rather than assumed:

| Risk | Handling |
|---|---|
| Callback driven by anyone | `msg.sender == triggerService`, an immutable resolved from `block.chainid`, plus `nonReentrant` |
| A swallowed failure marking the request EXECUTED | No `try`/`catch` anywhere on the path. A failed conversion reverts, the service records FAILED, and `retryTrigger` stays available |
| A request consumed by a failure | The record is deleted **before** the swap; a revert undoes the deletion with everything else, so a failed conversion leaves the request intact and retryable |
| A stuck request nobody can clear | `cancelScheduledEndow(requestId)`, curator or Guardian. A later callback for a cancelled id finds nothing and reverts |
| The fee eating bounty money | Paid by the caller through `msg.value`, never taken from tax. Change is refunded rather than quietly becoming bounty |
| A hardcoded fee going stale | `getFee()` is read at call time, as the service's own guidance requires |

**Verified on chain, not only on a fork.** On BNB testnet, request `31132`: 0.05 tBNB of tax
scheduled by the curator, executed by Flap's backend, `0.025758 BTCB` booked behind task 1,
`unassigned()` at zero and `solvent()` true. The transaction that performed the swap was not ours.

`test/TriggerEndow.t.sol` covers the path in 14 tests and is proven by breaking it: removing the
callback's sender check, wrapping the conversion in a `try`/`catch`, and reopening `endow` to the
curator each turn a specific test red.

**What remains.** The curator can still move the pool *before* scheduling, which lowers the spot
the floor is measured against. They cannot act on it: they do not submit the execution and cannot
predict its timing, so there is no position for them to close around it. A TWAP reference on the
floor would remove even that, at the cost of an oracle dependency and a staleness surface. Worth
Flap's opinion, but it is no longer the same class of finding.

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

**Description.** Rule 002 recommends a commission of 6% of `msg.value` for a tax rate ≤ 1%, and
`msg.value * 6 / taxRateBps` above it. This token launches at **200 bps each way**, which puts it
in the second tier: the recommended commission would be `msg.value * 6 / 200`, or 3%. This factory
takes none; 100% of the tax reaches bounties.

**Impact.** Strictly better for users than the recommendation, and worse for the vault developer, who earns nothing from the vault. Rule 002 asks for a justification when the recommendation is not followed.

**Justification offered.** The vault's purpose is to convert trading tax into verifiable work. A commission would reduce the prize for that work without funding any part of producing it. If a commission is wanted later it must be introduced at deployment of a new factory — this one has no parameter to change, which is also what makes it non-DOSable under Rule 001.

#### L-03: A large conversion used to land at any price at all — fixed
**Severity**: Low as reported, and it was the wrong finding
**Status**: Resolved — the bound now measures what everyone read it as measuring
**File**: `src/AssayFlapVault.sol` — `_requireWithinImpact`, `maxConvertible`, `spotUnitPrice`

**What was reported.** That tax accumulates and only converts when someone acts, so it can sit
indefinitely; and, in pre-audit review, that a large accumulated balance would **fail** to convert
because `MAX_ENDOW_SLIPPAGE_BPS` caps price impact at 3%.

**What was actually true.** The opposite, and worse. `MAX_ENDOW_SLIPPAGE_BPS` was compared against
`quote(bnbAmount)`, and `getAmountsOut` already prices the impact of that exact size — so the
bound could never object to it. It was a tolerance for the pool moving between scheduling and
execution, not a cap on impact, and nothing in the contract capped impact at all. Measured against
the live BTCB/WBNB pair, every size converted and none was refused:

| BNB in one call | landed below the untouched price | outcome before |
|---|---|---|
| 1 | 4 bps | accepted |
| 10 | 45 bps | accepted |
| 60 | 265 bps | accepted |
| 100 | 434 bps | accepted |
| 500 | 1,849 bps | accepted |
| 1,000 | 3,122 bps | accepted |
| 2,000 | **4,758 bps** | **accepted** |

Two thousand BNB converting in one call would have lost 47.6% of the tax and the contract would
have had no objection, because the floor was measured against the number that already contained
the loss.

**The fix.** `spotUnitPrice()` reads what the pool pays for an amount too small to move it, and
`_requireWithinImpact` compares the real output against that. The bound now means what it reads
as meaning. `maxConvertible()` publishes the largest amount that clears it, binary-searched
against the pool as it is — 68 BNB at the time of writing, and correct to the wei: impact at the
returned figure is 300 bps and at one-tenth of a BNB past it is 301. A refusal names the view, so
the failure teaches the fix.

Published rather than documented on purpose. A chunk size written into a document is a number
that goes stale the moment liquidity moves in either direction, and pre-audit review flagged
exactly that objection against a hardcoded cap.

**What remained, and no longer does.** Conversion used to depend on the curator or the Guardian
calling it, which stalled the vault's purpose whenever they did not. It is open to anybody now, and
the callback arms the next epoch itself, so it does not depend on anybody in particular either. A
balance above `maxConvertible()` still converts across more than one epoch, by design — that bound
is the price-impact ceiling and not a scheduling limit.

### Info

- **I-04** *(fixed)*: `AssayVault` originally had no rescue path for anything but its own
  `asset`, so a foreign ERC-20 mis-sent to it, or native coin forced in by `selfdestruct` or a
  block-reward payment, was unrecoverable by anyone. Rule 009 does not require otherwise — its
  subject is literally "Non-upgradeable **vaults**" and every line of its check table is scoped
  the same way, so the custody contract sits outside that guarantee by the specification's own
  wording. It was fixed anyway, because the moment to do it is while nothing is at stake.
  `sweepToken` and `sweepNative` join the existing `sweepUnaccounted`: all three are
  permissionless, all three send to the immutable `salvage` address, and none introduces a
  privileged role. Passing `asset` to `sweepToken` routes to the same surplus-only arithmetic, so
  the argument cannot widen the rule. For any other token the whole balance moves, guarded by a
  post-condition rather than an address comparison — `token != asset` does not prove a token
  cannot reach the `asset` balance, since a second entry point onto the same mapping passes that
  comparison, so the call instead reverts if this contract's `asset` balance fell by a single wei.
  `sweepable`/`sweepableNative` let a caller read what a sweep would move before paying for it.
  **The salvage address is the beneficiary of all foreign value**, including any future airdrop
  that lands here; that is the only fixed destination available without a privileged role, and it
  is stated here so nobody mistakes it for a hidden door.

- **I-05**: `AssayVault.deposit` credits the nominal `amount` to the ledger and then calls
  `safeTransferFrom` for that same amount. On a fee-on-transfer or rebasing asset the credited
  figure would exceed what actually arrived, `solvent()` would go false, and the last withdrawer
  would be short. `asset` is now the launched taxed-V3 token itself, which is exactly
  the case this note used to warn about — the protocol has one token, and stakes and pots are
  denominated in it. It is correct because that token taxes pool interactions, not wallet
  transfers: a measured `transfer` and `transferFrom` of 1,000 tokens between fresh addresses each
  deliver 1,000, at zero basis points. That is not left as a measurement somebody once took —
  `test/DepositParity.t.sol` asserts it against the live token on every run, so the day a token
  redeploy starts taxing plain transfers the suite says so, instead of the ledger quietly
  drifting. **This vault requires a standard-transfer asset**, and the one it has is checked to be
  one.
- **I-06** *(fixed)*: `error NotFrozen()` was declared and never thrown — a gate that was
  intended and not installed. It is thrown now, from `onlyController`, so no value moves until the
  controller set is sealed. This matters beyond tidiness: `deposit` takes a caller-supplied
  `from`, so a controller can pull against any standing allowance this vault has been granted and
  pay itself out, and `addController` and `freeze()` are separate transactions in a forge
  broadcast with a gap between them. Both live deployments are past that gap and every call site
  hardcodes `msg.sender` as the source, but the gap reopened on every future deployment. It no
  longer exists.


- **I-01**: `stats().openTasks` scans only the most recent `STATS_SCAN = 64` tasks. Beyond that it understates. Deliberate: the view is polled by a UI and an unbounded walk would get slower for exactly the vaults doing well. `tasks` and every amount are exact.
- **I-02**: `VaultBaseV2` and `VaultFactoryBaseV2` declare custom errors (`UnsupportedChain`, `OnlyVaultPortal`, …). These are Flap's own base contracts, unmodified, and outside UI-01's scope. Every revert authored in the two contracts audited here is a literal bilingual string. The tournament contracts behind them still use custom errors; they are not Flap vaults, their reverts do not surface in Flap's UI, and changing them would cost the type safety their own tests rely on.
- **I-03**: `collectable` and `collect` read `tournament.submissions` and `tournament.tasks`. The tournament is deployed alongside the vault and its correctness is load-bearing for every payout. It is immutable in the vault (`Tournament public immutable tournament`) and cannot be repointed.

## Resolved during audit

Found by working the checker's list against the contracts, and fixed before this report:

1. **UI-01 violation** — all eight custom errors in the vault and both in the factory were replaced with `require()` and literal `en / zh` strings.
2. **Rule 009 violation** — `emergencyWithdrawNative` and `emergencyWithdrawToken` were absent entirely; added verbatim to the rule's reference implementation, with `ReentrancyGuard`.
3. **Rule 003 violation** — `endow` accepted `minRewardOut = 0` from a privileged caller. Now bounded to 3% below spot; see M-02 for what remains.
4. **Rule 006 gaps** — no test covered the `receive()` gas budget, Guardian access, the factory's portal guard, `vaultDataSchema()`, or `description()` moving with state. `test/FlapSpec.t.sol` covers all of them.
5. **Custody rescue (I-04)** — `sweepToken` and `sweepNative` added, permissionless, to the
   immutable salvage address, guarded by a post-condition that an alias token cannot pass.
6. **The unthrown error (I-06)** — `onlyController` now requires the controller set to be sealed.
7. **Reentrancy hardening** — `endow`, `sponsor` and `collect` are now `nonReentrant`. `sponsor` in particular pulled tokens before updating state; the reward token is immutable BTCB so no callback exists today, but the ordering was wrong on its own terms.

## Centralization Analysis

### Admin controls
There is no owner, no admin role and no mutable parameter. Two addresses have capability:

| Actor | Can | Cannot |
|---|---|---|
| Curator (token creator, fixed at creation) | Post tasks of any legal length | Convert anything, size a conversion, choose which task is funded, or receive an unclaimed bounty — none of those are permissions any more, they are readings of state that anybody may act on | Withdraw unconverted tax as a permission — the epoch's state governs that, not the caller; name a recipient for anything; reach a scored miner's share; change any parameter |
| Guardian (Flap, fixed in `VaultBase`) | Everything the curator can, plus post a task if the curator's key is lost, plus the Rule 009 emergency drain | Be replaced or revoked; withdraw a window that is still open |
| Anyone | `sponsor` a bounty; `collect` a scored share; settle a finished window with `withdrawUnconverted`, which pays the curator address and never the caller; **post the next task once the previous one has settled**, for a window of at most `OPEN_POST_MAX_SPAN` | Settle a window while its task is still open; post while a task is live; post a window longer than ten minutes |

**Unclaimed rewards go back to the pool, all of them.** This paid the curator once, then paid the
curator only when nobody had scored, and now pays nobody at all. Review pushed twice and the second
push was right: once the project no longer chooses which task is funded or how much, "the project's
share" has nothing left to mean. `reclaimBounty` needs no permission either, because there is no
destination left to protect — the BTCB does not leave the vault and `endowed` does not move. The
project earns from the tournament the same way anybody does, by mining it.

`withdrawUnconverted` still pays the curator, and that is the one place the old rule survives: tax
that no task was ever opened against was never the tournament's to begin with. It is gated on the
epoch having closed, and anybody may trigger it.

Nothing about funding is the curator's to decide any longer. How much a conversion takes is the
window's whole accrual bounded by the impact ceiling; which task receives it is not asked, because
a conversion names none; when it happens is one epoch after the last, armed from inside the
callback. The self-arming path pays the scheduler out of tax, so it refuses a window worth less
than ten fees — otherwise a vault nobody trades against would spend more converting than it
converted, 288 times a day.

`TaskGenerator.generateAndPost()` is how an address with no tooling posts one: it takes no task
parameters, seeds from the previous block's hash, and draws, evaluates and compiles the whole task
on chain. Its gas is block-dependent — the seed decides how many draws are needed before one is
usable — so a caller must estimate generously. The first live call reverted out of gas at 474,590
against an estimate made one block earlier, and the same call with room succeeded at 1,318,610.
It sits behind a beacon owned by Flap's Guardian, the only upgradeable piece of the system and the
one address the tournament and the vault already treat as the trusted operator.

Open posting is a reviewer's suggestion, taken with one bound added. The tournament should not stop
because a key went quiet, so anybody may post in the gap between tasks. The bound exists because of
how it meets the withdrawal gate: `latestRevealEnd` is a high-water mark that no later post can
walk back, so an unbounded open post would freeze the project's own tax for thirty days for the
price of gas, with nothing able to undo it. Ten minutes for a stranger; the full range for the
curator and the Guardian.

That high-water mark is itself a correction. `latestRevealEnd` first read `tasks[taskCount]`, the
newest task by id — which is not the same as the task that closes last. Posting a short task beside
a long one moved the pointer to the short one, and two minutes later the gate opened while the long
task was still accepting reveals. `test/GateBypass.t.sol` demonstrates the sequence and now holds
it shut.

An earlier version of this table said the curator "cannot withdraw anything", which was not true:
`withdrawUnconverted` and `reclaimBounty` both existed and both paid the curator. What has changed
is not the destination — an empty window's tax belongs to the project by design, and that address
is fixed at construction — but who decides *when*. Reviewers pointed out that the withdrawal had no
"the window was empty" condition and was callable mid-task, next to miners who were still working.
It is now gated on the most recent task's reveal having closed, and the caller check is gone
entirely: while a window is open it reverts for the curator and the Guardian too, and once it has
closed anybody may pay the gas to settle it. A condition, not a permission.

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

The full suite ships in the audit archive, which states its own measured test and suite counts. Before mainnet:

1. Run `tools/rehearse.sh` against a mainnet fork as well as testnet — the reward venue differs by chain and only the testnet path has been walked end to end.
2. Deploy to BNB testnet and exercise `endow` and `collect` through `testnet.flap.sh` rather than only through the local preview.
3. Have the partner firm review M-02 specifically; it is the finding where an in-contract fix has real trade-offs and an outside opinion is worth the most.

## Conclusion

Both contracts satisfy every mandatory rule in the Flap vault specification. No Critical or High findings are open. The Medium findings are the Guardian authority the specification itself mandates, and a residual sandwich exposure that is bounded but not closed; both are disclosed in the source rather than only here. The vault is, in my assessment, ready for testnet deployment and for submission to a partner audit.

## Disclaimer

This self-check does not guarantee the absence of bugs or vulnerabilities. Smart contracts should undergo multiple audits and extensive testing before mainnet deployment. It follows Flap's published rule set and reflects the contracts at the commit noted above; any change after that point invalidates it.
