# Flap Vault Interaction Risk Report — response

Project: ASSAY (`AssayFlapVault`) · Vault Security Rating: High

Seven findings, all answered below. One is a false positive; the other six are accepted and fixed.

Three of the six turned out to be the same defect wearing different clothes: a guard written at one
call site and not at the second one that needed it. We are stating that plainly rather than
presenting six unrelated fixes, because the pattern is the more useful finding.

---

## Finding 1 — SYS-REQ-LITERAL-ERRORS

Custom errors and standalone revert used instead of `require()` with literal string messages.

**Status: [x] TP  [ ] FP  [ ] By Design  [ ] Acknowledged**

Fixed. All 47 custom errors removed and all 65 revert sites converted to
`require(condition, "English / 中文")`:

| Contract | Errors | Revert sites |
|---|---|---|
| `src/Tournament.sol` | 20 | 25 |
| `src/AgentRoster.sol` | 10 | 13 |
| `src/AssayVault.sol` | 10 | 19 |
| `src/Crucible.sol` | 4 | 4 |
| `src/TaskGenerator.sol` | 2 | 2 |
| `src/PriceGuard.sol` | 1 | 1 |
| `src/AssayFlapVault.sol` | 0 | 1 standalone `revert(unicode"…")` |
| **Total** | **47** | **65** |

The standalone `revert(unicode"Unsupported chain / 不支持该链")` in the `AssayFlapVault` constructor
became a positive assertion after the chain branch — the form the rule asks for, and smaller than
the `if/else` it replaced.

We had read the rule as applying to the vault contract only, on the reasoning that the vault is
what Flap's UI renders. That was wrong: the rule covers any revert a user can reach, and every
contract listed is on a user path — enrolling calls `AgentRoster`, committing and revealing call
`Tournament`.

**Stated plainly:** the conversion loses the error arguments.
`InsufficientAccount(account, have, want)` is now
`require(have >= amount, unicode"Account is short / 账户余额不足")` and no longer carries the
amounts. We read that as the rule's intent — a message a user can read beats a value they cannot
decode — but it is a real loss of debugging detail, flagged rather than left to be found.

**Verify:**

```
grep -rn '^\s*error [A-Z]' src/*.sol           # 0 matches
grep -rn 'revert [A-Z]\|revert(' src/*.sol     # 0 matches
```

---

## Finding 2 — SYS-REQ-MULTILANG

Single-language status banner strings while the contract establishes bilingual intent.

**Status: [x] TP  [ ] FP  [ ] By Design  [ ] Acknowledged**

Fixed. Both `description()` banners are bilingual.

`src/AssayFlapVault.sol`: `No task yet / 尚未发布任务` · `Tax unconverted / 税款待兑换` ·
`Bounty live / 赏金进行中` · `Bounties collected / 赏金已领取`

`src/Tournament.sol`: `No task posted yet. / 尚未发布任务。` ·
`A task is open. Commitments are being taken. / 任务进行中，正在接受提交承诺。` ·
`Commitments are closed. Submissions are being revealed and assayed. / 承诺已截止，正在揭示并计量提交。` ·
`The latest task is settled. Winners may claim. / 最新一期已结算，获胜者可领取。`

**Why the vault's banners are shorter than the tournament's:** the factory embeds the vault's
creation code, and adding the Chinese left only 861 bytes under EIP-170. The obvious remedy —
moving `vaultUISchema()` out, at 7,015 bytes the largest single item in the vault — is not
available: `VaultBaseV2` declares it `public pure virtual`, and a `pure` override cannot call an
external contract. So the vault's banners were tightened instead; each still names its state in
both languages. `Tournament` deploys standalone and keeps the full sentences.

---

## Finding 3 — SYS-REQ-RESCUE-MECHANISM

Missing Guardian `receive()` forward switch (rescue mechanism incomplete).

**Status: [ ] TP  [x] FP  [ ] By Design  [ ] Acknowledged**

**Reason: auto-forward is optional in Rule 009, and the mechanism the rule does mandate is present
and tested.**

Rule 009 heads that section `## Optional: Auto-Forward (receive() Risk-Control Mode)` and scopes it
in the next line to vaults that "choose to implement auto-forward"; every row of its checklist is
prefixed **"Non-upgradeable vaults with auto-forward:"**. We did not choose to implement it, so
those rows do not apply. `grep -rn 'autoForward|setAutoForward|forwardAddress' src test script`
returns nothing — this is an unselected optional mode, not a missing mandatory one.

What Rule 009 does mandate, we have:

```solidity
// src/AssayFlapVault.sol
modifier onlyGuardian() {
    require(msg.sender == _getGuardian(), unicode"Only the guardian / 仅限守护者");
    _;
}
function emergencyWithdrawNative(address to) external onlyGuardian nonReentrant { … }
function emergencyWithdrawToken(address token, address to) external onlyGuardian nonReentrant { … }
```

`_getGuardian()` is a per-chainid constant in `VaultBase.sol` with no setter and no role registry,
so the hatch cannot be taken away. `test/FlapSpec.t.sol` proves the gate by breaking it: the curator
and an ordinary address both revert and the tax does not move. The vault is deployed by
`new AssayFlapVault(...)` in `AssayFlapFactory.sol:54` — not a proxy — so it is on the
non-upgradeable branch, whose mandatory items are all satisfied. `receive()` only emits an event and
makes no external call, so the Rule 005 gas ceiling is not in play either.

**If Flap wants the optional switch anyway, we will add it, but we would be adding a known
conflict:** `freeTax()` is `address(this).balance - reserved`, so forwarding incoming BNB out of the
vault would leave already-reserved conversions unfunded and the scheduled swap would fail. Not
implementing it is the safer configuration for this vault, which is why it was not implemented.

---

## Finding 4 — `fundTaskFromPool` lets anyone route the entire reward pool to any task

**Status: [x] TP  [ ] FP  [ ] By Design  [ ] Acknowledged**

Accepted, and our own earlier fix for this was **incomplete** — worth saying, because the incomplete
version had a test and looked closed.

We had already added a guard requiring the task not be settled:

```solidity
require(block.timestamp < revealEnd, unicode"Settled / 已结算");   // one phase too late
```

That is a phase too late. Commitment closes at `commitEnd`, not `revealEnd`
(`Tournament.sol`: `require(block.timestamp < t.commitEnd, …)`), so across the entire reveal window
the field is already frozen while funding still worked. Anyone holding a commitment on a task nobody
funded could wait for that window, move the whole pool onto it, and take a share of a pot no one
else could still enter for — a sole committer taking all of it.

**Fix:** gate on `commitEnd`, so the pot is decided before the set of people dividing it is.

```solidity
(, uint64 commitEnd,,,,,,,) = tournament.tasks(taskId);
require(block.timestamp < commitEnd, unicode"Commitment closed / 承诺已截止");
```

The one-shot rule is a dedicated `pooledInto[taskId]` flag rather than `bounty[taskId] == 0`,
because `sponsor` is open to anyone and one wei of BTCB otherwise made a task permanently
unfundable — a denial for the price of dust.

---

## Finding 5 — Self-arming re-schedule over-reserves BNB by the scheduler fee

**Status: [x] TP  [ ] FP  [ ] By Design  [ ] Acknowledged**

Accepted, reproduced on a testnet fork against the real Trigger Service.

`_arm` nets out the fee the caller sent with the transaction. `trigger()` re-arms with
`_arm(fee, 0)`, where the fee leaves the vault's *own* balance — which is tax — and the code still
reserved the un-netted amount. Measured: armed amount `5e16`, balance `4.98e16`, reserved `5e16`,
over-reserved by exactly one fee (`2e14`). The next callback then tries to swap more BNB than the
vault holds, `swapExactETHForTokens` fails, and `trigger()` reverts with no `try/catch` around it.

The manual path had the netting; the self-arming path is the second call site and never got it.

**Fix:**

```solidity
uint256 free = freeTax();
uint256 amount = free > incoming ? free - incoming : 0;
if (incoming == 0) {                 // the vault is arming itself: the fee comes out of tax
    if (amount <= fee) return 0;
    amount -= fee;
}
```

The subtraction is also floored rather than written bare. That was proposed as a second defect —
a stalled vault reading `freeTax()` as zero while a caller still sends a fee, underflowing instead
of reaching `Nothing to convert / 无可兑换`. **We could not reproduce it as an independent bug:**
`_arm` returns early on `address(this).balance < fee + incoming`, which catches the empty-vault case
before the subtraction, and the states where `freeTax() < incoming` all appear to require the
over-reservation above to have happened first. We floored it anyway because it costs nothing and the
condition is one line away from reachable, but we are reporting it as unproven rather than claiming
a fix for a bug we could not demonstrate.

For the record, the stall was recoverable rather than permanent — `retryTrigger` is permissionless
and succeeds once a fee's worth of new tax arrives — but the vault could sit stopped indefinitely on
a quiet market, which is the condition it is most likely to be in.

---

## Finding 6 — `collect` uses the live bounty as the pot, making payouts collection-order dependent

**Status: [x] TP  [ ] FP  [ ] By Design  [ ] Acknowledged**

Accepted, reproduced on a fork.

`sponsor` had no time gate at all. `collectable` reads the live `bounty[taskId]` as the pot, and
`collect` books each miner once, so a sponsorship landing between two equal-scoring miners' calls
pays the second one more than the first. Measured with two miners on identical scores and a 0.1 BTCB
bounty: Alice collects first and receives `50e15`; a sponsor adds `100e15`; Bob receives `100e15`.
Same score, twice the money, decided by who called first — and `50e15` is stranded until
`reclaimBounty` can take it back after the claim window.

This is not a theft route — a sponsor who is also a miner always loses money doing it — but it is a
free lever for favouring one miner over another, and an honest late sponsorship silently punishes
whoever collected promptly.

**Fix:** the same gate `fundTaskFromPool` already had, at the site that was missing it.

```solidity
(,, uint64 revealEnd,,,,,,) = tournament.tasks(taskId);
require(block.timestamp < revealEnd, unicode"Settled / 已结算");
```

`collect` requires `block.timestamp >= revealEnd`, so the bounty is now frozen before the first
possible collection and every miner divides the same pot.

---

## Finding 7 — Custody note promises "no sweep of endowed funds" but emergency withdrawals can drain them

**Status: [x] TP  [ ] FP  [ ] By Design  [ ] Acknowledged**

Accepted. The note was wrong, not the code — so we changed the note.

`emergencyWithdrawToken(address(reward), to)` is `onlyGuardian` and transfers the full
`balanceOf(address(this))` without reading or reducing `endowed`. The Guardian can therefore take
BTCB owed to already-scored miners while `bounty[]`, `endowed` and `stats().committedBtcb` still
report it as present. That contradicted the header's absolute "no sweep of endowed funds".

**We are not changing the code.** Rule 009 requires that exact signature of every non-upgradeable
vault — no `amount` parameter, caller-specified `to`, full balance — and a `bal - endowed` guard
would violate it. A compromised vault is precisely the case where the full balance must be
removable. The gap is the price of the escape hatch.

**We changed the header to state both exceptions**, including one the finding did not mention:
`withdrawUnconverted` sends not-yet-converted tax to the fixed curator address, which is also not a
scored miner. `solvent()` is the reading that makes the first gap visible from outside, and
`test/FlapSpec.t.sol` asserts that it goes false after a Guardian drain.

---

## The pattern underneath findings 4, 5 and 6

All three are one defect: a guard written at one call site and not at the second.

| The guard | Where it was | Where it was missing |
|---|---|---|
| Task must still be open | `fundTaskFromPool`, but keyed to the wrong phase boundary | the reveal window, where the field is already frozen |
| Fee is not convertible tax | `triggerConversion` (manual path) | `_arm(fee, 0)` (self-arming path) |
| Bounty frozen before collection | `fundTaskFromPool` | `sponsor` |

Each had a passing test covering the site that was guarded. We have added tests at the sites that
were not, and each new test was confirmed by breaking the guard it covers and watching only that
test fail.

---

## Status

- Both `description()` banners bilingual; no custom errors or standalone reverts remain in `src/`.
- Findings 4, 5 and 6 fixed in `AssayFlapVault`; finding 7 fixed in its documentation.
- Both chains will be redeployed from this source before submission, so the deployed bytecode
  matches the packaged source; the packaging step verifies that byte for byte.
- No token has been launched on either chain.
