# Audit Summary — response

Project: ASSAY (`AssayFlapVault`) · Responding to rounds 1–13 · 6 Not Fixed, 18 Fixed

**021 and 024 are one defect, and they were not fixed. You are right to have failed them.** Both are
closed in this submission by a contract constant, not by an operational note. The other four are
answered below; two of them were accepted by your own challenge rounds and are listed here only
because the summary's status line disagrees with its challenge result.

We also disclose one issue you did not report, found while fixing 021.

---

## Finding 021 + Finding 024 — the same defect, now fixed

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged

**021** says converted tax can fail to reach the task it was accrued for. **024** says a task cannot
receive more than one conversion slice. We answered 024 by deleting the `pooledInto` flag and 021 by
calling the window an operational parameter. Both answers were wrong in the same way, and the reason
is worth stating because it is why 024 came back after being reported fixed.

**The flag was never what capped a task at one conversion. The window was.**

`fundTaskFromPool` can only pay a task while its commit window is open. `CONVERSION_INTERVAL` is 300
seconds. The shipped spec gave a task **60 seconds**. A task's window therefore covered one fifth of
one conversion period: four tasks in five could never be funded from tax at all, and no task could
ever receive more than a single conversion's worth. Removing `pooledInto` left that cap exactly
where it stood while appearing to answer the finding.

**And it was not a deployment setting anyone could correct.** We described it as a choice about
`tasks/epoch.json`. That file is regenerated from scratch every epoch by `script/GenTask.s.sol`,
which writes the literal `"commitSeconds": 60`. The sixty was not sitting in a config waiting to be
edited — it was being reissued into every task the machine posted.

**Fix — `Tournament.MIN_COMMIT_SPAN`:**

```solidity
uint64 public constant MIN_COMMIT_SPAN = 5 minutes;

// in postTask, after the general window check:
if (msg.sender == curator || msg.sender == _getGuardian()) {
    require(
        commitEnd >= block.timestamp + MIN_COMMIT_SPAN,
        unicode"Commit window too short / 承诺窗口过短"
    );
}
```

A window at least one full interval long always contains a moment at which the rate limit permits a
conversion, whatever phase it is in when the task is posted. So the rate limit can no longer be the
reason an epoch's tax missed that epoch's task. `script/GenTask.s.sol` now writes `600`.

**Why the floor binds curated posts only.** `fundTaskFromPool` pays a task whose poster is the
curator or the Guardian and no other, so a stranger's task cannot receive the converted tax however
long its window stays open. Imposing the floor on open posts would spend their span — which
`OPEN_POST_MAX_SPAN` caps at ten minutes precisely so one stranger cannot sit on the fallback path
(finding 023) — to buy them a guarantee they are not eligible for. Applying it to everything was our
first attempt and it left open posts with no legal window at all.

**Tests.** `test_AWindowShorterThanTheCadenceCannotBePostedAtAll` replaces the test that used to
reproduce the defect: the broken configuration is now refused at posting.
`test_TheShippedSpecSatisfiesTheFloor` posts the number `GenTask.s.sol` actually writes.
`test_MinCommitSpanCoversTheConversionCadence` asserts the two constants against each other across
the two contracts that hold them — nothing else connects them, and that is how this survived the
round in which it was reported fixed. `test_TheOpenPostFallbackStillHasALegalWindow` checks the
floor did not brick the path 023 is about.

Confirmed by lowering `MIN_COMMIT_SPAN` to 60: the drift gate fails with `60 < 300` and the posting
test fails with "next call did not revert as expected", while the other three still pass.

---

## Newly disclosed — the fallback path cannot be paid the tax at all

Not reported by the audit; found while fixing the above, and reported rather than left to be found.

`TaskGenerator` is deployed infrastructure — a beacon proxy whose implementation the Guardian
controls — and it exists so the tournament survives the curator going quiet. It calls
`tournament.postTask` **as itself**, so its tasks carry `poster == address(generator)`, which is
neither the curator nor the Guardian. Every task the fallback path produces is therefore one the
converted tax can never reach, while `triggerConversion` stays permissionless and the pool it cannot
reach keeps growing.

`test_AGeneratorPostedTaskCannotBeFundedFromThePool` measures it: newest task, commit window open,
money in the pool, and no caller can bring the two together.

Not changed in this submission, and we would rather say why than ship it under audit pressure. The
gate exists because of finding 004 — a poster who funds their own task and competes in it alone. To
let generator tasks through, the vault would need to recognise the generator's address, which means
new mutable state and a Guardian-only setter on a contract with 2.5KB of EIP-170 headroom, added
after the audit rather than before it. What a fallback task can still be paid is a pot escrowed at
posting and `sponsor`, which is open to anyone; what it cannot be paid is the accumulated tax. We
will implement the recognition if you would rather have it than the smaller diff.

---

## Finding 013 — the stated failure mode is inverted

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged  (fixed in the previous round)

> *Not Fixed Reason: trigger() can still use the stale stored floor when an execution-block pool
> manipulation makes the fresh quote lower, allowing output below a current-market 3% floor.*

The code takes the **higher** of the two floors:

```solidity
uint256 floorNow = s.minRewardOut;
try this.quote(s.bnbAmount) returns (uint256 out) {
    uint256 fresh = (out * (10_000 - MAX_ENDOW_SLIPPAGE_BPS)) / 10_000;
    if (fresh > floorNow) floorNow = fresh;
} catch { /* the stored floor stands */ }
```

Taking the maximum of two floors cannot admit an output below the smaller of them. Trace the exact
scenario named: a manipulator pushes the pool down in the execution block, so `fresh < stored` and
the code uses `stored`. The manipulated pool cannot deliver `stored` — that is what "pushed down"
means — so `swapExactETHForTokens` reverts, the `try/catch` added for finding 016 catches it,
`ConversionFailed` is emitted, the BNB stays free and the callback re-arms at a floor priced against
the market that just moved. Nothing is extracted; the manipulator has bought one skipped conversion
with their own gas and slippage.

The real cost of the maximum is the opposite one, and we accept it: a genuine downward move blocks
the conversion until it is re-armed. That is liveness, not loss, and it is handled by the same catch.

Happy to add a fork test that manipulates the pair downward and asserts nothing leaves, if the
argument above is not sufficient.

---

## Finding 017 — the claim was not source-verifiable; corrected

> **Status:** `[ ]` TP　`[ ]` FP　`[ ]` By Design　`[x]` Acknowledged

> *Challenge: it imposes no bound on the number of scoring miners. Thus the per-task remainder is not
> source-verifiably limited to single-digit wei.*

Correct, and the offending part was our figure, not the code. "Single-digit wei" assumed a turnout
the source does not bound. The bound that **is** derivable: `(pot * score) / totalScore` performs
exactly one division per scoring miner and each loses strictly under one wei, so the remainder is
under `scorers` wei for any number of miners. That is what
`test_TheRoundingDustIsBoundedByTheNumberOfScorers` asserts — `bounty - paidOut <= scorers` — and it
is the arithmetic itself rather than an estimate of participation. The NatSpec now says this instead
of the figure you refused.

Still not fixed, for the reason given before: paying the remainder out means giving it to whoever
collects last, which reintroduces the collection-order dependence finding 006 made us remove. As
your own note observed, the dust is not lost — `reclaimBounty` rolls it into `rewardPool`, so it
stays prize money and belongs to a later cohort.

---

## Finding 003 — your challenge accepted this as FP

> **Status:** `[ ]` TP　`[x]` FP　`[ ]` By Design　`[ ]` Acknowledged

Unchanged, and we are not re-arguing it. Round 1's challenge result reads: *"The stated Guardian
Requirements do not require a receive()-time auto-forward switch, so its absence does not establish
the claimed rescue-mechanism defect."* The summary's Not Fixed Reason restates the original finding
rather than the challenge that resolved it.

---

## Finding 023 — your challenge accepted this as acknowledged

> **Status:** `[ ]` TP　`[ ]` FP　`[ ]` By Design　`[x]` Acknowledged

Unchanged. Round 12's challenge result reads: *"a stranger-posted task cannot receive converted vault
rewards... so monopolizing open posts does not create the described treasury fund-loss path."* Both
measurements stand: `test_AGrieferHoldsTheOpenSlotAgainstAnHonestStranger` and its control, plus
`test_ANonZeroPotIsNotARealCostBecauseItComesRightBack`.

Note the interaction with the new floor: `MIN_COMMIT_SPAN` deliberately does not bind open posts, so
nothing here changes the cost or the reach of the griefing this finding describes.

---

## Status

- 252 tests pass. The two new gates were confirmed by breaking what they guard and watching only
  their own tests fail.
- No token has been launched on either chain.
- **Both chains are now behind this source, and deliberately so.** `MIN_COMMIT_SPAN` changes
  `Tournament`, and `Tournament` is immutable and constructor-wired into the vault, so adopting it
  on chain means redeploying the set rather than upgrading one contract. We are not spending that
  before the review: the addresses below run the previous revision, and this submission is the
  source we intend to deploy once it passes. The testnet address is a revision older still — that
  deploy failed for gas and the public BNB testnet faucet is out of funds.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x6b220DACd22467e837249344399A5d52951Ae264` | `0x6c06Bc4f0e3D2df402a56CC52FB2D2C1907f1972` |
| `Tournament` | `0x2d14990a90640435CdbE13BA80e9c57e81d9c5dd` | `0xBF69D8e7ad7495C280aB01ded60Ff8DF5e209b37` |
| Tax token | not launched | not launched |
