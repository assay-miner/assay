# Flap Vault Interaction Risk Report — response

Generated: 2026-09-07 · Project: ASSAY (`AssayFlapVault`)

Both findings are real. One is fixed. One was already accepted in an earlier round, and this round
found that the test carrying that acceptance did not measure what it claimed — that is corrected
below rather than restated.

---

## Risk Findings
### Finding 1: withdrawUnconverted can be held shut indefinitely through the permissionless drawn lane
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** AssayFlapVault.withdrawUnconverted gates on tournament.latestCuratedRevealEnd, which is advanced by every drawn OR curated postTask. Because TaskGenerator.generateAndPost is fully permissionless and posts on the drawn lane, any actor can keep latestCuratedRevealEnd perpetually in the future by re-posting a drawn task each time the previous drawn task's reveal window elapses, so the reclaim path (which is supposed to become available to anyone once the epoch settles) can be denied for everyone indefinitely.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol:withdrawUnconverted`
  - `src/Tournament.sol:postTask (latestCuratedRevealEnd assignment)`
  - `src/TaskGenerator.sol:generateAndPost`

> **Status:** `[ ]` TP　`[ ]` FP　`[ ]` By Design　`[x]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Correct. The mechanism is `Tournament.sol:373`'s `if ((drawn || curated) && revealEnd > latestCuratedRevealEnd)` on a lane anyone can post to. Not fixed because the only fix — hold the withdrawal for a *funded* epoch — reads `bounty[]`, which a stranger can write with one wei through the permissionless `sponsor` over exactly the interval the freeze covers. That is finding 025's shape moved onto a different gate, not a repair of it. What is frozen is the curator's claim on tax from windows nobody mined; conversions, bounties and the Guardian's hatch are unaffected, and `test/WithdrawalFreeze.t.sol` fails if that stops being true.

**The boundary is an ordering race, not a closed gate.** Both gates are `>=` —
`src/AssayFlapVault.sol:812` for the withdrawal, `src/Tournament.sol:292` for the drawn lane — so
the next drawn post is legal in the very block the last one ends and the griefer never has to skip
a block. But at exactly `block.timestamp == latestCuratedRevealEnd` the withdrawal gate *passes*
too. Holding it shut therefore costs the griefer winning that same-block ordering race once per
epoch, not merely paying gas. `test_AtTheBoundaryTheWithdrawalIsCallable` is new this round and
withdraws successfully at precisely that instant, so the cost is written down as a test rather than
asserted as a closed door.

**Correcting our own previous evidence.** In the earlier round we cited
`test_AStrangerKeepsTheWithdrawalShutAcrossEpochs` as reproducing this. It did not.
`TaskGenerator`'s windows are `COMMIT_SECONDS + REVEAL_SECONDS` = twenty minutes, while
`Base.t.sol:109`'s *curated* fixture task holds `latestCuratedRevealEnd` two hours out, so all
three of the stranger's drawn posts ended inside that mark and never cleared the `>` at
`Tournament.sol:373`. The three reverts were caused by the curator's own task; the test passed with
`generateAndPost` contributing nothing. It now starts past the curated mark and asserts each round
that the stranger's post is what moved it — confirmed by deleting `generateAndPost` from the loop,
which fails exactly that test and leaves the other four in the file green.

**And no attacker is needed.** `test_TheProtocolsOwnLoopShutsItToo` posts only what the project
posts for itself, and the curator's `withdrawUnconverted` reverts across the whole window, opening
only when the project's own curated reveal elapses. What a griefer adds is keeping it shut in the
one state where it would otherwise open — when the protocol has stopped running.

**Why no fix ships.** The obvious one is to hold the withdrawal only for a drawn epoch that was
actually funded. That reads `bounty[]`, and `bounty[]` has two writers: `fundTaskFromPool`, and
`sponsor` at `src/AssayFlapVault.sol:671`, which is `external` and permissionless. Its gates are
`nonReentrant`, `require(amount > 0)`, `_requireTask(taskId)`, and — since the fix we shipped for
your earlier `sponsor` finding — `require(block.timestamp < revealEnd)`. **None of them binds this
attack**: that last gate is open over exactly the interval the withdrawal is frozen, because a drawn
post sets `latestCuratedRevealEnd = revealEnd` (`src/Tournament.sol:373-374`) and the freeze holds
while `block.timestamp < latestCuratedRevealEnd` (`src/AssayFlapVault.sol:812`). One wei of BTCB per
drawn epoch rebuilds the freeze exactly. The marginal cost is one `sponsor(taskId, 1)` call —
measured in-test at 82,019 gas on the first epoch and 38,219 on each one after, excluding the
transaction floor; the figure moves with warm/cold state and we quote it as an order of magnitude
rather than a constant. This repository already carries
`test_DustSponsorshipCannotBlockPoolFunding` because one wei of somebody else's BTCB could make a
task permanently unfundable — the same dust-jam primitive, moved onto a different gate. **A gate
that reads a value a stranger can write is the shape of finding 025, not a fix for it.**

**The accepted cost is bounded and asserted.** The gate that shuts the withdrawal is
`tournament.latestCuratedRevealEnd()`, and `triggerConversion` never reads it, so tax keeps becoming
BTCB — one conversion per `CONVERSION_INTERVAL` — while the withdrawal is shut, reaching miners
instead of the curator, which is the direction this protocol exists to move money.
`test_AFrozenWithdrawalDoesNotStopConversions` fires a conversion from a stranger in exactly the
frozen state, and `test_TheGuardiansHatchIsUnaffected` takes the tax out through
`emergencyWithdrawNative` while the curator's own call is reverting. The accurate statement of the
cost is *beyond the curator's reach*, not *beyond reach*. If a future change makes a frozen
withdrawal also stop conversions, that file goes red and this disposition expires with it.

### Finding 2: AgentRoster reverse index is never cleared on identity transfer, locking a new NFT owner out of enrolment
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** AgentRoster.minerOf[agentId] is only cleared by the currently-bound miner calling withdraw(). If that miner never withdraws (in particular after they transfer/sell the ERC-8004 identity NFT to a new owner), the binding persists to the seller's address, and the new legitimate owner cannot enroll that agentId because enroll() reverts on `minerOf[agentId] != address(0)`, even though they pass the isAuthorizedOrOwner check.
- **Vulnerable Code:**
  - `src/AgentRoster.sol:enroll`
  - `src/AgentRoster.sol:withdraw`
  - `src/AgentRoster.sol:minerOf`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed. `enroll` re-checks the binding against the registry and releases it when the registry says the bound address no longer holds the identity; a registry that cannot answer releases nothing. Disclosed below: our first version of this fix opened a HIGH-severity commitment replay taking N/(N+1) of a pot for zero work against a single honest miner — measured at 50.0% with one replay leg and 75.0% with three — caught by an adversarial pass before deployment and closed by requiring `minerOf[agentId] == miner` in `requireEnrolled`.

**Verified, and it is not only about sales.** `minerOf[agentId]` was cleared in exactly one place —
`withdraw`, by the bound miner. The buyer passed `isAuthorizedOrOwner` and `enroll` refused them
anyway, and the only key that could release the binding was the one that had just sold them the
identity. `AgentRoster`'s own header documents the delegation this design enables — the NFT can stay
in cold storage while a disposable hot key does the mining — so **every rotation of that hot key hit
this too**: the identity's owner locked out of their own agent id by their own retired key.

**Disclosure: our first fix was worse than the bug.** It released the binding and guarded `withdraw`
so it clears `minerOf` only when it still points at the caller. Fifteen tests passed. It was wrong.

Releasing the binding leaves the old holder's `_enrolments` entry intact — deliberately, their stake
is in it — and `requireEnrolled` only ever read `_enrolments[miner].agentId`. So **one identity
backed any number of live enrolments**, and the damage was not dilution. `Tournament.commit` places
no uniqueness constraint on `commitment` across miners and `submissions` is a public mapping, so the
released holder copies the current holder's commitment verbatim, waits for them to reveal, and
replays the same `(runtime, salt)`. It verifies, because `reveal` hashes against `s.agentId` and both
carry the same one. A copied runtime scores identically — `score` is a pure function of `gasUsed`
against the task baseline — so against a single honest miner **N replay legs take exactly N/(N+1) of
the pot**. Measured on the fixture with the guard removed: **500‰ with one leg, 750‰ with three**,
and every leg's stake is withdrawn in full afterwards. `Tournament`'s own NatSpec is what we had
deleted the premise of — "a stolen `(runtime, salt)` pair hashes to a different commitment under a
different agent id" held only while an id had one enrolled miner.

**Both halves shipped.** `requireEnrolled` now requires `minerOf[agentId] == miner`. One call site,
`Tournament.commit`; `withdraw` does not come through it, so a released holder keeps their stake and
can take it out — they simply cannot commit again. And the registry query is wrapped in `try/catch`
whose **catch keeps the binding**: it runs before the "already bound" refusal, so a registry that
reverts on demand would otherwise have been a way to release *every* binding, and an OZ ERC-721
reverts on a burned id in normal operation. A query that cannot be answered is not an answer that
the holder lost the identity — the same direction finding 013 needed.

**Why the existing test did not catch either.** `test_OneIdentityCannotBackTwoMiners` was green
throughout all of this. It asserts the invariant using a second miner who was never authorised for
the identity, so it never reached the path that broke. The new tests use an authorised second key:
`test_ABuyerCanEnrolAnIdentityTheSellerNeverUnbound`,
`test_TheSellerCanStillWithdrawAfterLosingTheBinding`, `test_ALiveBindingCannotBeTaken`,
`test_AReleasedHolderCannotCommitAgain` and `test_AnUnanswerableRegistryReleasesNothing`. Confirmed
red by removing the binding check from `requireEnrolled`: exactly
`test_AReleasedHolderCannotCommitAgain` fails and the other sixteen in that file hold.

---

## Also disclosed this round — not in your report

**Our recorded launch address was already occupied, and the deploy had no gate that would notice.**
`script/MineSalt.s.sol` — the script an operator actually runs to produce `SALT` — defaulted its
search offset to `1`. Scanning from a fixed low offset returns the *first* salt on the venue whose
predicted clone ends in `0x7777`, which is the salt every identical scan returns: `0x…0002dc5c`,
landing on `0x7516947d…957777`. That address has held an EIP-1167 clone of Flap's taxed-V3
implementation since block 98,443,003 (2026-05-15), sixteen weeks before our deploy. `Deploy.s.sol`
already derived its own offset from the deployer; the second call site did not, and
`mineVanitySalt`'s NatSpec had warned about exactly this fixed start without any code enforcing it.

It was not caught at deploy time because the only check compared a *launched* token against the
prediction, and with `SKIP_TOKEN=true` there is no launch to compare. Meanwhile `AssayVault` takes
`predictedToken` in its constructor and holds it in an immutable, so the previous deployment's
custody contract was permanently bound to a token this project does not control.

Three changes, all in `script/`, none touching the audited contracts:

- `Deploy.s.sol` refuses the entire deploy if `predictedToken.code.length != 0`
  (`PredictedTokenTaken`). Confirmed red: re-running with the old salt reverts before any broadcast.
- `mineVanitySalt` is `view` rather than `pure` and skips any predicted address that already holds
  code — whether an address is free is a question only the chain can answer.
- `MineSalt.s.sol` derives its default offset from the deployer, the same way `Deploy.s.sol` does.

The addresses in the table below are a fresh deployment on a re-mined salt, and its
`predictedToken` returns empty from `eth_getCode`.

---

## Status

- **275 tests pass across 36 suites.**
- **BSC mainnet redeployed and carries exactly this source.** Every *contract* address in the
  manifest holds code, asked of the chain rather than assumed: the eight this deploy created, plus
  the third-party ERC-8004 `identityRegistry` they point at. The manifest's remaining entries are
  not contracts — `curator`, `deployer` and `salvage` are one EOA, and `flapVault` and `taxToken`
  are the zero address. `AgentRoster`'s deployed runtime was compared byte for byte against the
  local artifact: 214 bytes differ and **all 214 fall inside the immutable regions** the artifact
  declares — four immutable values (`identityRegistry`, `vault`, `minStake`, `deployer`) embedded at
  twelve code offsets — so the code itself is identical. `tournament.curator()` returns the
  deployer; deployer, curator and salvage are one key, not three addresses.
- **BSC testnet: nothing of ours deployed.** The chain-97 manifest records a deploy whose
  transactions never landed. `eth_getCode` is empty for every contract that manifest says *we*
  deployed; the one address in it that does hold code is the third-party ERC-8004 registry we read
  (`script/Deploy.s.sol:70`), not something we deployed. `tools/sync-submission.mjs` asks the chain
  and labels that table accordingly rather than presenting it as a proof deployment.
- **No token is launched.** `SKIP_TOKEN=true`; `taxToken` and `flapVault` are both the zero address
  in `deployments/56-latest.json`, and `predictedToken` `0x0570411C…907777` is empty on chain. A
  rehearsal token from an earlier round exists on testnet at
  `0x769EfAbeFc18317A846A1E2BdeB831Ba659f7777`, which `test/DepositParity.t.sol` forks chain 97 to
  assert against on every run.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | not deployed | `0x09410940e6ffb6F31195fBF84b50344A066Ca70D` |
| `Tournament` | not deployed | `0xfb758f1FAeDF978cDe416c5d1D47908F7C07f2cB` |
| `AssayVault` (approve this) | not deployed | `0xBC3Fe16a8a2Ce2535158dF27E032822eEaF0AFA1` |
| `AgentRoster` | not deployed | `0x273c802566245473fD5aEd1EFA88A853B3adbFD3` |
| `TaskGenerator` | not deployed | `0x2db55A8D9BEcf73d173726330985d342fc3a888A` |
| Curator (`withdrawUnconverted` pays) | — | `0x9E591947199091D4ff23DCF9Ab1C88576bd550e8` |
| Tax token | rehearsal token, see above | not launched |
