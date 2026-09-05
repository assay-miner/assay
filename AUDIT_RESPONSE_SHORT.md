# Flap Vault Interaction Risk Report — response

Generated in reply to the report of 2026-09-04 17:15 UTC · Project: ASSAY (`AssayFlapVault`)

Accepted. Both halves hold. The first is fixed; the second is acknowledged with a measured reason,
not waved away. Two things in the report are understated and one is overstated, all three below.

The second half is a regression we introduced. Finding 015 was closed by adding
`latestCuratedRevealEnd`, advanced **only** by curator/Guardian posts, precisely so a permissionless
poster could not hold the withdrawal shut. Closing finding 025 put `drawn` back into that predicate
while making the drawn lane public. We re-latched the gate we had closed, and say so here rather
than let it read as a new discovery.

---

### Finding 1: Permissionless generateAndPost has no inter-epoch spacing

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged  *(relocation — fixed)*
> **Status:** `[ ]` TP　`[ ]` FP　`[ ]` By Design　`[x]` Acknowledged  *(withdrawal freeze — see below)*

**Measured on a fork against the shipped code.** Relocation costs one `generateAndPost`: 1.13M gas,
about five cents at the 0.05 gwei this project's own mainnet deploys paid. **Two calls in the same
block relocated the target twice** — the lane had no spacing rather than loose spacing. What it
denies the displaced task's miners is every conversion not yet swept onto it, and a drawn task
carries `pot = 0`, so before the pool has moved that is the entire epoch — plus their stake, which
`roster.lockUntil` holds to a reveal that will now pay nothing.

**Understated, twice.**

*The shipped ops script was deterministically attackable.* `script/PostTask.s.sol` draws at one line
and funds at the next inside a single `vm.startBroadcast()` — but a forge broadcast is N separate
transactions, and the gap between them is insertable. An attacker landing one `generateAndPost()`
there made the operator's own `fundTaskFromPool` revert with "Not the drawn task", aborting the run
and leaving their own task the only fundable one. No bidding war, no monitoring, five cents, every
time.

*The withdrawal freeze is the default, not only an attack.* Every drawn post pushes
`latestCuratedRevealEnd` twenty minutes out. At the cadence the protocol is designed to run,
`withdrawUnconverted` never opens — with no attacker present at all.

**Overstated, in one direction worth stating precisely.** A bounty already moved by
`fundTaskFromPool` cannot be touched: relocation does not write `bounty[]`, and a miner who scored on
the displaced task still collects exactly what was moved onto it. `rewardPool` is not frozen either,
only redirected — anyone re-funds the new target for 47,609 gas. And `triggerConversion` has no epoch
gate, so a frozen withdrawal does not strand BNB: it keeps converting into prize money. What the
curator loses is the claim to empty-window tax, not the money's existence. Finally, "relocate at
will" is true as to *which task* and not as to *which instance* — the attacker still cannot choose
what is drawn, so this is a timing lever, not the information advantage finding 025 was about.

**Fix — serialise the drawn lane on its own last epoch:**

```solidity
require(
    block.timestamp >= tasks[latestGeneratedTaskId].revealEnd,
    unicode"Drawn epoch still running / 抽取任务尚未结束"
);
```

Reading the **drawn** task's reveal rather than `latestRevealEnd` is the whole of it. A stranger
occupying the open-post slot advances `latestRevealEnd`; a funding lane waiting on that mark would
hand finding 023's griefer the treasury's only route to miners, which is why the lane was left
ungated in the first place. This waits on a mark nobody outside the lane can advance.
`latestGeneratedTaskId` is 0 before the first draw and `tasks[0].revealEnd` is 0, so the first post
is unconditionally allowed. It also closes the ops race without a helper contract: the operator's own
drawn task is running, so the insertion is exactly what this refuses.

**Two things we tried and rejected, because the reasoning matters more than the diff.**

Our instinct was to serialise *and* drop `drawn` from the `latestCuratedRevealEnd` predicate. A probe
falsified the second half: with it dropped, unconverted tax sitting under a live, **funded** drawn
epoch becomes sweepable by the curator. The predicate is untouched.

We also rejected a `DRAWN_LANE_GAP` constant that would reopen the withdrawal periodically, because
it does not tune what it appears to. `withdrawUnconverted` takes `freeTax()`, which is the tax
accrued since the last `_arm`, and arms are `CONVERSION_INTERVAL` apart — so a one-second window and
a one-minute window let a sweeper take the same amount. "Shrink the gap to shrink the leak" is a
wrong model of the leak. Worse, sweeping once per epoch keeps the balance permanently under
`FEE_COVER_MULTIPLE * fee`, at which point `_arm` returns 0 and the self-arming chain stops: the
mitigation can starve the pool it exists to protect.

**Why the withdrawal freeze is Acknowledged.** Every fix we found opens a periodic, un-closable
sweep channel whose size is set by `CONVERSION_INTERVAL` rather than by the window, and which can
starve the conversion chain outright. The cost of the freeze is bounded and falls on us: the curator
cannot reclaim tax from windows nobody mined. Nothing is stranded — conversions continue, miners keep
being paid, and the Guardian's emergency withdrawals are unaffected. We would rather carry that than
ship a mitigation that can stop the protocol paying at all. If Flap would rather have the channel, we
will add it.

**Two comments said the opposite of the code and are corrected.** `TaskGenerator` claimed "this posts
as a stranger, so it only succeeds in the gap after the previous task has settled" — it posts on the
drawn lane, which had no gap, and describing one the code did not have is a fair part of why nobody
went looking for it. The vault claimed "no poster can make their own task the funding target by
posting after it", which was true of a curated poster and of nobody else until this change.

**Tested.** `test_TheFundingTargetCannotMoveWhileItsEpochRuns` (same block, and every point inside
the epoch), `test_TheLaneReopensWhenTheEpochCloses` (serialises rather than seizes),
`test_AStrangerHoldingTheOpenSlotCannotBlockTheDrawnLane` (constraint A held),
`test_NobodyCanWedgeADrawBetweenTheOperatorsDrawAndItsFunding` (the ops race),
`test_TheLaneRunsEpochAfterEpoch` (three consecutive epochs). Confirmed red by removing the require:
exactly those fail with "next call did not revert as expected" and the other nine hold.

`test_EveryBlockYieldsATask` asserted the old behaviour and now asks `drawFor` directly — it was
always about the redraw loop rather than the posting cadence, and posting twenty times would have
been testing the cadence instead.

---

## Status

- 261 tests pass.
- **BSC mainnet redeployed for this submission and carries exactly this source.** `Tournament` is
  immutable and constructor-wired to both the vault and the generator, so no change here can be an
  upgrade. Verified by call in both directions: `tournament.generator()` returns
  `0x6fF13305bCa28Aae1fe624619afAb94F736DaB3D` and that proxy's `tournament()` returns `0xB0A91CeA508492B76A4f7339b62417695E025D00`.
- **BSC testnet is behind** — that deploy failed for gas and the public faucet is out of funds.
- **No token is launched on mainnet.** `SKIP_TOKEN=true`; `taxToken` is the zero address in
  `deployments/56-latest.json`. A rehearsal token from an earlier round exists on testnet at
  `0x769EfAbeFc18317A846A1E2BdeB831Ba659f7777`, which `test/DepositParity.t.sol` forks chain 97 to
  assert against on every run.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x6b220DACd22467e837249344399A5d52951Ae264` | `0xb24c25Cf8D94449527E31E3Ba32296aF7c8e6D5D` |
| `Tournament` | `0x2d14990a90640435CdbE13BA80e9c57e81d9c5dd` | `0xB0A91CeA508492B76A4f7339b62417695E025D00` |
| `TaskGenerator` | — | `0x6fF13305bCa28Aae1fe624619afAb94F736DaB3D` |
| Tax token | rehearsal token, see above | not launched |
