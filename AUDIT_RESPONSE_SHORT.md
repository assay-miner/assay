# Flap Vault Interaction Risk Report — response

Generated: 2026-09-07 · Project: ASSAY (`AssayFlapVault`)

Both findings are real. One is fixed. One was already accepted in an earlier round and the
acceptance is carried by tests, not by a paragraph.

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
> **Reason (if FP / By Design / Acknowledged):** Correct and reproduced — a stranger paying only gas keeps it shut across consecutive epochs, and the `>=` serialisation leaves no block in between. Not fixed because the only fix — hold the withdrawal for a *funded* epoch — reads `bounty[]`, which a stranger can write with one wei through the permissionless `sponsor`, rebuilding the freeze for 92,273 gas. That is finding 025's shape moved onto a different gate, not a repair of it. What is frozen is the curator's claim on tax from windows nobody mined; nothing is stranded, and `test/WithdrawalFreeze.t.sol` fails if that stops being true.

**Reproduced, not argued.** `test_AStrangerKeepsTheWithdrawalShutAcrossEpochs` runs three
consecutive epochs from `STRANGER`, asserts the revert each time, and warps to *exactly*
`revealEnd` between them — the gate is `>=`, so the next drawn post is legal in the very block the
last one ends and there is no instant at which the withdrawal is callable.

**And no attacker is needed.** `test_TheProtocolsOwnLoopShutsItToo` is `script/PostTask.s.sol`'s own
draw-then-fund loop, and it shuts the withdrawal for the whole epoch by itself. That decides how the
finding should be read: what a griefer adds is keeping it shut in the one state where it would
otherwise open — when the protocol has stopped running.

**Why no fix ships.** The obvious one is to hold the withdrawal only for a drawn epoch that was
actually funded. That reads `bounty[]`, and `bounty[]` has two writers: `fundTaskFromPool`, and
`sponsor` at `src/AssayFlapVault.sol:650`, which is `external`, permissionless, and bounded only by
`require(amount > 0)`. One wei of BTCB on each drawn epoch rebuilds the freeze exactly, for a
measured 92,273 gas on top of a post the project makes anyway — each epoch is a fresh `bounty[]`
slot, so it is the cold price every time. This repository already carries
`test_DustSponsorshipCannotBlockPoolFunding` because one wei of somebody else's BTCB could make a
task permanently unfundable — the same dust-jam primitive, moved onto a different gate. **A gate
that reads a value a stranger can write is the shape of finding 025, not a fix for it.**

**The accepted cost is bounded and asserted.** `triggerConversion` carries no epoch gate, so tax
keeps becoming BTCB while the withdrawal is shut — it reaches miners instead of the curator, which
is the direction this protocol exists to move money. `test_AFrozenWithdrawalDoesNotStopConversions`
fires a conversion from a stranger in exactly the frozen state, and
`test_TheGuardiansHatchIsUnaffected` takes the tax out through `emergencyWithdrawNative` while the
curator's own call is reverting. The accurate statement of the cost is *beyond the curator's reach*,
not *beyond reach*. If a future change makes a frozen withdrawal also stop conversions, that file
goes red and this disposition expires with it.

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
> **Reason (if FP / By Design / Acknowledged):** Fixed. `enroll` re-checks the binding against the registry and releases it when the registry says the bound address no longer holds the identity; a registry that cannot answer releases nothing. Disclosed below: our first version of this fix opened a HIGH-severity commitment replay that takes N/(N+1) of a pot for zero work — measured at 50.0% with one replay leg and 75.0% with three — caught by an adversarial pass before deployment and closed by requiring `minerOf[agentId] == miner` in `requireEnrolled`.

**Verified, and it is not only about sales.** `minerOf[agentId]` was cleared in exactly one place —
`withdraw`, by the bound miner. The buyer passed `isAuthorizedOrOwner` and `enroll` refused them
anyway, and the only key that could release the binding was the one that had just sold them the
identity. `AgentRoster`'s own header recommends mining from a disposable hot key with the NFT in
cold storage, so **every rotation of that hot key hit this too** — the identity's owner locked out
of their own agent id by their own retired key.

**Disclosure: our first fix was worse than the bug.** It released the binding and guarded `withdraw`
so it clears `minerOf` only when it still points at the caller. Fifteen tests passed. It was wrong.

Releasing the binding leaves the old holder's `_enrolments` entry intact — deliberately, their stake
is in it — and `requireEnrolled` only ever read `_enrolments[miner].agentId`. So **one identity
backed any number of live enrolments**, and the damage was not dilution. `Tournament.commit` places
no uniqueness constraint on `commitment` across miners and `submissions` is a public mapping, so the
released holder copies the current holder's commitment verbatim, waits for them to reveal, and
replays the same `(runtime, salt)`. It verifies, because `reveal` hashes against `s.agentId` and both
carry the same one. A copied runtime scores identically — `score` is a pure function of `gasUsed`
against the baseline — so against a single honest miner **N replay legs take exactly N/(N+1) of the
pot**. Measured on the fixture with the guard removed: **500‰ with one leg, 750‰ with three**, and
every leg's stake is withdrawn in full afterwards. `Tournament`'s own NatSpec is
what we had deleted the premise of — "a stolen `(runtime, salt)` pair hashes to a different
commitment under a different agent id" held only while an id had one enrolled miner.

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

## Status

- **274 tests pass.**
- **BSC mainnet redeployed and carries exactly this source.** Every manifest address holds code,
  asked of the chain rather than assumed. `AgentRoster`'s deployed runtime was compared byte for
  byte against the local artifact: 209 bytes differ and **all 209 sit inside the four immutable
  slots** the artifact declares, so the code itself is identical. `tournament.curator()` returns the
  deployer — deployer, curator and salvage are one key, not three addresses.
- **BSC testnet: nothing deployed.** The chain-97 manifest records a deploy that ran out of gas;
  `eth_getCode` is empty for every address in it, and `tools/sync-submission.mjs` asks the chain and
  labels that table accordingly rather than presenting it as a proof deployment.
- **No token is launched.** `SKIP_TOKEN=true`; `taxToken` is the zero address in
  `deployments/56-latest.json`. A rehearsal token from an earlier round exists on testnet at
  `0x769EfAbeFc18317A846A1E2BdeB831Ba659f7777`, which `test/DepositParity.t.sol` forks chain 97 to
  assert against on every run.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | not deployed | `0x358ABcb03db5DE8c3d692e02E58AA97670a937eA` |
| `Tournament` | not deployed | `0x73fc9f777B162972b33A68C0498638a99A13fc6C` |
| `AssayVault` (approve this) | not deployed | `0x3020b5E57BFe635dDA000d9fD00756F322D6530E` |
| `AgentRoster` | not deployed | `0xc58ed968EB39cb3378C386C53543DC7B32C18125` |
| `TaskGenerator` | not deployed | `0xF80285F7f555669395aCc1184DfC76c9BdBd3C6B` |
| Curator (`withdrawUnconverted` pays) | — | `0x9E591947199091D4ff23DCF9Ab1C88576bd550e8` |
| Tax token | rehearsal token, see above | not launched |
