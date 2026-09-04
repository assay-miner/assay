# Flap Vault Interaction Risk Report — response

Generated in reply to the report of 2026-09-04 · Project: ASSAY (`AssayFlapVault`)

Both findings accepted. They are one defect and one fix: the pool paid the only account that also
wrote the question, and the only task nobody wrote could not be paid at all.

---

### Finding 1: Curator can capture tax-funded BTCB bounties via pre-computed submissions and a minimal commit window (USER-RISK-MATTHEW-EFFECT)

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged

Accepted, and reproduced end to end on a fork before changing anything. Against the shipped epoch:
baseline 1624 gas, the stock hill-climbing client's ceiling 1592, the curator's own answer 1352.
Quadratic scoring makes that **98.63% of the bounty**; as sole scorer it is 100%.

**Two corrections to the report, one in each direction.**

The mechanism is not that only the curator can solve the task. `referenceRuntime` is a required
`bytes` argument, so it sits in public calldata, and `compileNaive` is a plaintext per-op encoding —
we recovered all nine drawn ops from it **without the seed** and rebuilt the curator's optimised
program byte for byte. A prepared opponent can compete. What cannot compete is the shipped client:
`miner/src/seeds.ts` returned an empty list without a `SEED` environment variable and said nothing
about it, so a miner without our file fired no shot at all. That is a client property, not a
protocol one, and it is fixed below.

In the other direction, the report understates it. The curator needs **no search advantage**:
`fundTaskFromPool` required the newest task, so posting a second task while miners were committing
to the first moved the pool onto it. Measured — the miners in the task they were working in collect
zero. That variant costs one `postTask`.

**What made it work was a conjunction, and neither half is wrong alone.** The poster chooses the
instance (the seed never reaches the chain — `GenTask.s.sol` reads it from the environment), and
`fundTaskFromPool` routed the pool to `poster == curator || poster == _getGuardian()`, a gate added
in an earlier round to stop a stranger funding and winning their own task. Together they say the
only task the tax can pay is a task authored by the account collecting it.

Barring the poster from competing is not the fix and we did not ship it: a second EOA costs nothing,
ERC-8004 identities are permissionless, and `AgentRoster.enroll` has no handle linking two
addresses. It would also erase `poster == winner`, a red flag anyone can check in one query.

**The fix: the funded task is one nobody chooses.**

`TaskGenerator` draws from `blockhash(block.number - 1)`. A caller cannot pin which block includes
their transaction, so the instance is unknown even to whoever triggers the draw. `Tournament` gains a
third lane and the vault follows it:

```solidity
// Tournament
address public immutable generator;
uint256 public latestGeneratedTaskId;      // written on the drawn lane and nowhere else

// AssayFlapVault.fundTaskFromPool
require(taskId == tournament.latestGeneratedTaskId(), unicode"Not the drawn task / 非抽取任务");
```

The poster whitelist is gone. `taskId == taskCount()` is gone with it, which closes the diversion
variant in the same line: a curated task posted after the drawn one is newer and still cannot take
the pool.

Three lanes, and which one a post is in decides its window rules and its eligibility:

| | window rules | may be funded |
|---|---|---|
| drawn | floors on **both** windows, capped by `DRAWN_MAX_SPAN` (1h), **not** gated on `latestRevealEnd` | yes |
| curated | `MIN_COMMIT_SPAN` floor, posts any time | no — pays only its own escrowed pot |
| stranger | `OPEN_POST_MAX_SPAN`, in the gap between tasks | no |

The drawn lane is deliberately not gated on `latestRevealEnd`. If it were, whoever wins the race to
occupy the open slot could hold the treasury's only route to miners shut — finding 023's mechanism
aimed at the money instead of at availability. It does advance `latestCuratedRevealEnd`, so
`withdrawUnconverted` is unchanged.

`MIN_REVEAL_SPAN` is new and binds the drawn lane, and `TaskGenerator`'s windows are constants rather
than caller arguments. A caller who could name the window would name a short one and be the only
person with time to answer the task the pool is about to fund — the same advantage on a new lane.

**`generator` is a constructor immutable, not a one-shot setter.** A full redeploy was mandatory
anyway: `Deploy.s.sol` calls `vault.freeze()` and `AssayVault.addController` is deployer-only and
refuses once frozen, so a new `Tournament` cannot attach to an existing vault. A setter would be a
lever that exists and has to be proven spent; an immutable never exists. The resulting cycle is
broken by predicting the proxy's address — **not** by deploying it uninitialized and initializing
later: `TaskGenerator.initialize` has no access control and a forge broadcast is N separate
transactions, so anyone could land `initialize(their own Tournament)` in the gap. With `generator`
immutable and `fundTaskFromPool` the only exit from `rewardPool`, every BTCB the vault ever converts
would be locked. The deploy asserts the prediction held, and it is verifiable by call:
`tournament.generator()` returns `0x7566de584af82CC2f2119c647945b7F47006560d` and that proxy's `tournament()` returns
`0x150d7d49F7eae9043fc5fa745A2fF5183d1F1927`.

**Tested, and confirmed red.** `test_ANewerCuratedTaskCannotDivertThePoolFromTheDrawnOne` pins the
variant the report did not name; `test_OnlyTheDrawnTaskCanBeFundedFromThePool` asserts both
directions — the curated task open and refused, the drawn task funded. Restoring the old poster gate
makes the first fail with "next call did not revert as expected" and the funding tests with "Not the
drawn task", while the rest of the suite holds.

---

### Finding 2: TaskGenerator posts pot=0 tasks that can never be funded, yet occupy the single open-post slot

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged

Accepted. We disclosed the first half ourselves in the previous round and did not fix it, on the
grounds that letting generator tasks through meant new state on a vault with little headroom. That
reasoning does not survive finding 1: the two are the same defect seen from opposite ends. The only
task whose instance nobody chose was the only task the tax could not pay, and the only task the tax
could pay was written by the account collecting it. Inverting the gate answers both.

The occupation half is fixed by the same change and in the way the finding asks for. The drawn lane
no longer reads `latestRevealEnd` at all, so a generator post neither waits for the open slot nor
holds it against anyone. A stranger's fallback post is unaffected — `OPEN_POST_MAX_SPAN` still bounds
it, and finding 023's cost analysis is unchanged.

`test_TheDrawnLaneIsNotBlockedByALiveTask` posts a curated task with a distant reveal and then draws
anyway. `test_TheGeneratorsWindowIsNotCallerChosen` asserts the windows are the constants and that
both clear the floors `Tournament` enforces, so the belt and the braces agree rather than one of them
being the only thing holding.

---

## The off-chain half, shipped in the same revision

A fix that moved the money to a lane no miner could see would have been worse than the finding.
`miner/src/seeds.ts` read the instance from a `SEED` environment variable and `return []`-ed
silently without one. It now reads the seed from `Generated(taskId, seed, caller)` and resolves the
draw through `TaskGenerator.drawFor(seed)` — the same selection `generateAndPost` makes, redraw loop
included — and every failure path logs the reason instead of returning an empty list.

`drawFor` is public for that reason and one more: the redraw loop depends on a private
`_informative`, so nothing outside the contract could tell which draw a seed settles on. Tests could
not either.

## Also fixed, found by the same pass

`test_TheWindowsAreMachineSized` asserted `vm.contains(gen, '"commitSeconds": 60')`. That is a
substring of `600`, so the gate that exists to notice the commit window opening up stayed green when
it went 60 → 600 in the previous round, and would have at 60000. It parses the number and bounds
both sides now.

## Status

- 253 tests pass.
- **BSC mainnet redeployed for this submission and carries exactly this source.** `Tournament` is
  immutable and constructor-wired to both the vault and the generator, so this change could not be
  an upgrade. The packaging step's bytecode check passes against the addresses below.
- **BSC testnet is behind** — that deploy failed for gas and the public faucet is out of funds.
- **No token is launched on mainnet.** `SKIP_TOKEN=true`; `taxToken` is the zero address in
  `deployments/56-latest.json`. A rehearsal token from an earlier round exists on testnet at
  `0x769EfAbeFc18317A846A1E2BdeB831Ba659f7777`, which `test/DepositParity.t.sol` forks chain 97 to
  assert against on every run.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x6b220DACd22467e837249344399A5d52951Ae264` | `0x33D6144E14f08b19f98983c7Ce7c2F805d56da4D` |
| `Tournament` | `0x2d14990a90640435CdbE13BA80e9c57e81d9c5dd` | `0x150d7d49F7eae9043fc5fa745A2fF5183d1F1927` |
| `TaskGenerator` | — | `0x7566de584af82CC2f2119c647945b7F47006560d` |
| Tax token | rehearsal token, see above | not launched |
