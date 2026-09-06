# Audit Summary — response

**Contract:** assay-vault-audit__9 · Six Not Fixed findings, all six answered below.

Two of them (003 and 023) are answered by this summary's own Feedback Challenge results, which
read "Accepted" while the status line reads Not Fixed. Two more (017 and 021) quote Feedback we
replaced in later rounds. One (028) is fixed in the source you are holding. The sixth (027) is a
status of ours that was wrong, and we are correcting it rather than defending it.

---

### Finding 003: Missing Guardian receive() forward switch (rescue mechanism incomplete)
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** rule_review
- **Description:** AssayFlapVault implements facet (a) of the required Guardian rescue mechanism (emergencyWithdrawNative and emergencyWithdrawToken, both Guardian-only, draining BNB and any ERC20 including the reward token), but does not implement facet (b): a Guardian-controlled forward switch on receive(). The receive() function only emits RevenueReceived and has no Guardian-settable flag/forward address that, when enabled, forwards all incoming BNB to a safe address via a non-reverting low-level call and returns early. During an incident the Guardian cannot redirect ongoing incoming tax revenue to safety; it can only repeatedly drain accumulated balances after the fact.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol:receive`
  - `src/AssayFlapVault.sol:emergencyWithdrawNative`

> **Status:** `[ ]` TP　`[x]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Unchanged, and this round's summary contradicts its own adjudication: your Round 1 Feedback Challenge on this finding reads "Accepted: ... The stated Guardian Requirements do not require a receive()-time auto-forward switch, so its absence does not establish the claimed rescue-mechanism defect." Auto-forward is the optional mode of Rule 009 and we did not select it — `grep -rn 'autoForward|setAutoForward|forwardAddress' src test script` returns nothing, so there is no half-built switch to finish. What the rule mandates is present: `emergencyWithdrawNative` and `emergencyWithdrawToken`, both `onlyGuardian` and `nonReentrant`, against a `_getGuardian()` that is a per-chainid constant with no setter. If Flap wants the optional switch we will add it, but it fights this vault's accounting: `freeTax()` is `balance - reserved`, so forwarding incoming BNB out leaves already-reserved conversions unfunded.

### Finding 017: Integer truncation in per-miner bounty split leaves undistributed dust
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** rule_review
- **Description:** In AssayFlapVault.collectable/collect, each scoring miner's share is computed as (bounty[taskId] * score) / totalScore with floor division against a fixed pot. The sum of all floored shares is strictly less than the full bounty whenever totalScore does not evenly divide the products, so a small remainder is never paid to any miner. The leftover is not lost to the protocol (reclaimBounty later rolls bounty[taskId] - paid[taskId] back into rewardPool for a future task), but the dust is not distributed to the scoring miners of the current task. (rule COM-ROUNDING)
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol:collectable`
  - `src/AssayFlapVault.sol:collect`

> **Status:** `[ ]` TP　`[ ]` FP　`[ ]` By Design　`[x]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Acknowledged, and the argument you refused has already been withdrawn — the Feedback quoted in this round's summary is our older one. Your Round 8 challenge was right that "single-digit wei" assumed a turnout the source does not bound, so that figure is gone. The bound that IS derivable: `(pot * score) / totalScore` performs exactly one division per scoring miner and each loses strictly under one wei, so the remainder is under `scorers` wei for ANY number of miners. That is the arithmetic itself, not an estimate of participation, and it is what `test_TheRoundingDustIsBoundedByTheNumberOfScorers` asserts — `bounty - paidOut <= scorers`. The NatSpec at test/PoolDrain.t.sol:385-390 states the N-independent form and records why the earlier one was refused. Still not fixed, for the reason given before: paying the remainder out means giving it to whoever collects last, which reintroduces the collection-order dependence finding 006 made us remove. As your own description notes, the dust is not lost — `reclaimBounty` rolls it into `rewardPool`, so it stays prize money and belongs to a later cohort.

### Finding 021: An epoch's converted tax can fail to fund that epoch's task because tax-funding is only permitted during the commit window while conversions are rate-limited
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** fundTaskFromPool() may only assign the reward pool to the current task while `block.timestamp < commitEnd`, but conversions that fill the pool run at most once per CONVERSION_INTERVAL (5 minutes) at times chosen by the Trigger Service. If the pool has not yet received the epoch's converted tax before the current task's commitEnd, that task can never be funded from the pool; the tax instead accumulates in rewardPool and is only assignable to a LATER task. Miners who committed to the current task in reliance on a tax-funded bounty may receive nothing from tax for that epoch.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: fundTaskFromPool() require(block.timestamp < commitEnd, ...)`
  - `src/AssayFlapVault.sol: CONVERSION_INTERVAL / _arm scheduling cadence`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed since the Feedback this round's summary quotes, which is our older Acknowledged answer. The rate limit can no longer be the reason an epoch's tax misses its epoch's task, because the window is now a contract constant rather than an ops file: `Tournament.MIN_COMMIT_SPAN` and `MIN_REVEAL_SPAN` are 5 minutes each and bind the funded lane, and `TaskGenerator` posts with `COMMIT_SECONDS = REVEAL_SECONDS = 10 minutes` as constants a caller cannot name. A 600-second commit window against a 300-second cadence always contains a moment at which the limit permits a conversion, whatever phase it is in. The earlier answer treated `tasks/epoch.json`'s sixty seconds as a deployment choice; it was not, because `script/GenTask.s.sol` rewrites that file every epoch, so the number was reissued into every task. What remains true is that the Trigger Service picks its own execution moment, so a conversion can still land after a given commitEnd — that money is not lost, it funds the next drawn epoch, and no task's advertised bounty is ever reduced after miners see it because funding happens at posting.

### Finding 023: Open-post fallback can be monopolised by a griefer via latestRevealEnd high-water mark
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** During a curator/Guardian outage, any address may post tasks through Tournament.postTask's open-window branch. Open posts are gated by `require(block.timestamp >= latestRevealEnd)`, and every post raises `latestRevealEnd` (a monotonic high-water mark) by up to OPEN_POST_MAX_SPAN. A griefer who posts a trivial (pot=0) task taking the boundary block each cycle keeps `latestRevealEnd` permanently ahead of `block.timestamp`, winning the posting race repeatedly and preventing other honest strangers from posting fallback tasks. The fund-locking aspect was mitigated by moving the vault's withdrawal gate to `latestCuratedRevealEnd`, but the open-poster-vs-open-poster monopoly on the fallback path remains.
- **Vulnerable Code:**
  - `src/Tournament.sol: postTask (open-window branch, latestRevealEnd gate)`

> **Status:** `[ ]` TP　`[ ]` FP　`[ ]` By Design　`[x]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Unchanged, and as with 003 this round's summary contradicts its own adjudication: your Round 12 Feedback Challenge reads "Accepted: ... monopolizing open posts does not create the described treasury fund-loss path." Both mitigations remain measured rather than argued: `test_ANonZeroPotIsNotARealCostBecauseItComesRightBack` shows a pot is not a cost because `reclaim` returns it whole the instant `revealEnd` passes with `totalScore == 0`, and a per-address cooldown does not survive a second EOA. One thing has changed in this finding's favour since we last answered it: the reward pool no longer follows any open post at all — it follows the drawn lane, which does not read `latestRevealEnd`, so a griefer holding the open slot cannot touch the treasury's route to miners. What remains is availability of the stranger fallback, not funds.

### Finding 027: Permissionless generateAndPost has no inter-epoch spacing, letting anyone relocate the reward-pool funding target and stall the reward flow
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** The reward pool is only ever payable to `latestGeneratedTaskId`, which is written exclusively on the drawn lane of `Tournament.postTask`. `TaskGenerator.generateAndPost()` is fully public and, because it calls `postTask` from the generator address, always takes the drawn lane. Unlike the stranger lane (which requires `block.timestamp >= latestRevealEnd`, i.e. only in the gap between epochs), the drawn lane enforces no inter-epoch gap. Any address can therefore call `generateAndPost()` at will (~gas only) to publish a fresh drawn task, which resets `latestGeneratedTaskId` to that new task. `fundTaskFromPool`'s comment claims 'no poster can make their own task the funding target by posting after it,' but that guarantee only covers *winnability* (the instance is drawn from a blockhash). It does NOT prevent moving the target: an attacker can repeatedly post new drawn tasks so the pool follows a task that active miners have not committed to, causing all future converted tax to bypass the task those miners are working. The same spam also advances `latestCuratedRevealEnd` on every drawn post, keeping `withdrawUnconverted` permanently reverting.
- **Vulnerable Code:**
  - `src/TaskGenerator.sol:generateAndPost`
  - `src/Tournament.sol:postTask (drawn lane, missing latestRevealEnd gap)`
  - `src/AssayFlapVault.sol:fundTaskFromPool`

> **Status:** `[ ]` TP　`[ ]` FP　`[ ]` By Design　`[x]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Correcting our own status. We marked this TP last round, which was right for the relocation half and wrong for the withdrawal half — leaving a "will fix" standing against something we deliberately did not fix. The relocation half is fixed and stays fixed: the drawn lane is serialised on its own last epoch at `Tournament.sol:288-291`, so the funding target cannot move off a task miners have committed to. Your sentence about the withdrawal is accurate as written and we are not fixing it; the disproof of the obvious fix is below, because it is the useful part.

### Finding 028: postTask pot deposit approval targets the wrong contract in Tournament.vaultUISchema
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** Tournament.postTask escrows its pot by calling AssayVault.deposit, which executes asset.safeTransferFrom(poster, AssayVault, pot). The token allowance therefore has to be granted to AssayVault. However, Tournament.vaultUISchema declares postTask with an ApproveAction ("taxToken", "pot"), and the Flap schema semantics fix the approve spender to the schema-owning contract itself (Tournament). A poster who follows the generated UI approves Tournament, but the actual pull is performed by AssayVault, so postTask reverts inside safeTransferFrom for any task created with a non-zero pot.
- **Vulnerable Code:**
  - `src/Tournament.sol: vaultUISchema (postTask ApproveAction)`
  - `src/Tournament.sol: postTask (vault.deposit call)`
  - `src/AssayVault.sol: deposit (asset.safeTransferFrom(from, address(this), amount))`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed, and verifiable in the archive you are holding: `grep -c 'ApproveAction("taxToken", "pot")' src/Tournament.sol` returns 0. The declaration is gone and `postTask`'s description now carries what it would have arranged — a non-zero pot needs an ASSAY allowance to the custody contract at `vault()`, not to the tournament. It cannot be declared correctly: `ApproveAction` is `{ tokenType, amountFieldName }` with no spender field, and `vaultUISchema` is `pure`, so it cannot read `vault()` to name the address either. Making `Tournament` the puller instead would put the pot inside a logic contract between two statements and give a hostile token a reentrancy hook into `postTask`, which has no guard. `test_PostTaskDeclaresNoApprovalBecauseItIsNotThePuller` demonstrates both directions — approving the tournament reverts, approving `vault()` posts — and `tools/check-schema.mjs` now refuses any method that declares an `ApproveAction` without `safeTransferFrom(msg.sender, address(this), ...)` in its own body.

---

## Finding 027 — the fix we built, and the one wei that defeats it

The disproof is the useful part of this answer, so it is set out rather than summarised.

**The candidate.** Drop `drawn` from the `latestCuratedRevealEnd` predicate, restoring 015 exactly,
and have `withdrawUnconverted` refuse only while the latest drawn task is **funded** — a spam post
carries `bounty == 0` and holds nothing, so the permanent freeze becomes bounded by real epochs. Its
premise was that the vault reads `bounty[]`, which it already owns.

**`bounty[]` has two writers, not one.** `AssayFlapVault.sol:485` is `fundTaskFromPool`.
`AssayFlapVault.sol:662` is `sponsor`, which is `external`, permissionless, and bounded only by
`require(amount > 0)`. One wei of BTCB on each drawn epoch rebuilds the permanent freeze exactly:
measured across six consecutive epochs, the curator receives nothing, at 84,563 gas on top of a post
the project makes anyway. The serialisation gate is `>=`, so a single atomic
`generateAndPost + sponsor` relocks in the instant the previous epoch ends and no block is ever open.

Against the current code — 932,639 gas and zero BTCB for the same permanent freeze — the candidate
raises the attacker's price by about 9%. That is a price, not a fix.

**This codebase already knew that primitive.** `test_DustSponsorshipCannotBlockPoolFunding` exists
because one wei of somebody else's BTCB could make a task permanently unfundable. The candidate moved
the same dust jam onto a different gate — a gate reading a value a stranger can write, which is the
shape of finding 025 rather than a fix for it.

**What survives it, and why we are not shipping that either.** A version that holds only on a
vault-private mark written inside `fundTaskFromPool`, with a minimum sized against
`FEE_COVER_MULTIPLE * fee`, and a counter so that only newly-converted money can hold — each layer
proven necessary by removing it and watching the freeze come back. That is two new storage variables
and new accounting inside `_convertToPool`, on a vault with 2.5KB of EIP-170 headroom, added after
the audit rather than before it, to close a denial of our own claim. We would rather carry the cost.

**What the Acknowledged actually accepts, pinned as tests rather than prose.**
`test/WithdrawalFreeze.t.sol` asserts three things:

- the freeze is real and repeatable across consecutive epochs, for gas alone;
- **the protocol's own loop produces it with no attacker at all** — `generateAndPost` then
  `fundTaskFromPool` is `script/PostTask.s.sol`'s sequence, and it shuts the withdrawal for the whole
  epoch. So what a griefer adds is keeping it shut in the one state where it would otherwise open,
  which is when the protocol has stopped running;
- and the basis of the decision: a frozen withdrawal stops nothing else. `triggerConversion` has no
  epoch gate and still arms while frozen, so tax keeps becoming prize money and reaching miners
  rather than the curator, and the Guardian's hatch is unaffected. If a future change makes a frozen
  withdrawal also stall conversions, that file fails and this cost stops being acceptable.

The accurate statement of the cost is that the curator cannot reclaim tax from windows nobody mined.
It is not that the money is stranded.

---

## Status

- 266 tests pass.
- **No contract changes this round, and therefore no redeploy.** The only addition is
  `test/WithdrawalFreeze.t.sol`, which does not affect bytecode. The mainnet addresses below are the
  ones you verified last round and the packaging step's bytecode check passes against them.
- **BSC testnet is behind** — that deploy failed for gas and the public faucet is out of funds.
- **No token is launched on mainnet.** `SKIP_TOKEN=true`; `taxToken` is the zero address in
  `deployments/56-latest.json`. A rehearsal token from an earlier round exists on testnet at
  `0x769EfAbeFc18317A846A1E2BdeB831Ba659f7777`, which `test/DepositParity.t.sol` forks chain 97 to
  assert against on every run.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x6b220DACd22467e837249344399A5d52951Ae264` | `0xF5b3243259daA0E9b0CE8f51F6340a89e50B404F` |
| `Tournament` | `0x2d14990a90640435CdbE13BA80e9c57e81d9c5dd` | `0x5196Bbe37D76df30F4Eeb412846946f78E85eb25` |
| `AssayVault` (approve this) | — | `0x76033A5F2020FB177DeC06481f032800dA37ae2A` |
| `TaskGenerator` | — | `0xEEB91744BCA82DCA2fc09513e5a76bdCaE4589B9` |
| Tax token | rehearsal token, see above | not launched |
