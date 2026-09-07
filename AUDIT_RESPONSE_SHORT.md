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

## Requested change — every contract is now upgradeable, Guardian-owned

> *All contracts should be made upgradeable, with the upgrade authority assigned to the Guardian.*

Done. Every contract is an implementation behind an `UpgradeableBeacon` whose `owner()` is Flap's
Guardian, `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b`. `TaskGenerator` already had this shape; the
other six now use exactly the same one — `Initializable`, `_disableInitializers()` in the
constructor, and an `initialize` carrying the old constructor's body unchanged.

**Beacon rather than UUPS**, for a measurable reason: `Tournament` was 22,814 bytes against
EIP-170's 24,576, and UUPS puts its upgrade machinery in the implementation. A beacon keeps it in
the beacon. Converting six immutables to storage cost 286 bytes, and it now sits at 23,100 with
1,476 to spare. `AssayFlapVault` came out 137 bytes *smaller*.

**`AssayVaultDeployer` is deleted.** It existed only because `new AssayFlapVault(...)` inside
`AssayFlapFactory.newVault` put the vault's entire creation code into the factory's runtime. The
factory creates a `BeaconProxy` now, so the problem it was invented for does not exist.

**Every proxy is constructed with its initializer calldata.** None of these initializers has access
control, and a `forge script` broadcast is N separate transactions, so a proxy deployed with empty
init data would sit uninitialized across a block boundary with `initialize` open to anyone. The one
genuine cycle — `Tournament` and `TaskGenerator` name each other — is resolved by predicting the
generator proxy's address rather than by deferring its initialization, so no gap opens there either.

**Verified on chain, not asserted.** For all seven: `beacon.owner()` is the Guardian,
`beacon.implementation()` matches the manifest, and each proxy's ERC-1967 beacon slot points at its
own beacon. Every implementation's deployed runtime is **byte-for-byte identical** to the local
artifact — with the immutables gone there are no immutable slots left, so the comparison is exact
rather than "differences fall inside declared slots".

`test/UpgradeAuthority.t.sol` asserts this about the stack the deploy script actually builds: all
seven behind beacons, the Guardian owning every one, no other address able to upgrade any of them,
an upgrade preserving state, and no implementation initializable on its own.

| Contract | Proxy (use this) | Beacon | Implementation |
|---|---|---|---|
| `Tournament` | `0xC1707fDDc579339061DC47Edbd912687903EC916` | `0x049d28b81821cF719e3811B4666fC8Ed2D50B965` | `0x6CA9bdd3749aB51a4E08631126ca63b464B90ab5` |
| `AssayVault` | `0x720F48484Bfe5D22BAe679c531B53C70607A62dD` | `0xd07FE44376bE3563131C0bD5C32b7007B3F7f4d8` | `0xB3718fabb7DA3043490b3C9a43EC8B45c92F747e` |
| `AgentRoster` | `0xdef12257719A1f36072fa8132673bb65CC4A370B` | `0xc059Ae8110055e03978093bE291fE4f07AEf5c99` | `0x567785326d9A22469D899B72FE8E068B352E13ca` |
| `PriceGuard` | `0xD33451cD95A8b513a69227e4cB53d391de5895Fb` | `0x70A0341df82dC334D72650F6014EaC6540cC684C` | `0x25C1810Ab6D5a7370E91830D19704e45EE1f446C` |
| `TaskGenerator` | `0x1660623253ceCd17d4db986563Bd8Ac65D1824dC` | `0xe16C524F936fD924Ff18E866067DCe1B72b546e1` | `0x2F2F1C92Eba9469efd67379e5760DeA38Df68656` |
| `AssayFlapFactory` | `0x0dEcCDEb5816773Ce962e4F6b4f74fa0de7E9663` | `0xAFDC4519E793A40970dFD4CB82b9ca4d8FA4597b` | `0x155855Fd0c07057aba0c41F53f713D3Fe2E53c84` |
| `AssayFlapVault` | one per token, minted by the factory | `0x111998780B5d4aa390C928c8357eF62A5baD3EBD` | `0x42774E431670745f058778f54792205B3b3b9301` |

Beacon owner on every row: `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b`.

---

## Also disclosed — our recorded launch address was already occupied

`script/MineSalt.s.sol` — the script an operator runs to produce `SALT` — defaulted its search
offset to `1`. Scanning from a fixed low offset returns the *first* salt on the venue whose predicted
clone ends in `0x7777`, which is the salt every identical scan returns: `0x…0002dc5c`, landing on
`0x7516947d…957777`. That address has held an EIP-1167 clone of Flap's taxed-V3 implementation since
block 98,443,003 (2026-05-15). `Deploy.s.sol` already derived its own offset from the deployer; the
second call site did not.

It was not caught at deploy time because the only occupancy check compared a *launched* token
against the prediction, and with `SKIP_TOKEN=true` there is no launch to compare — while
`AssayVault` takes `predictedToken` in its initializer and holds it, so custody would have been
bound to a token this project does not control.

Three changes, all in `script/`, none touching the audited contracts: `Deploy.s.sol` refuses the
entire deploy if `predictedToken.code.length != 0` (confirmed red — re-running with the old salt
reverts before any broadcast); `mineVanitySalt` is `view` and skips occupied addresses; and
`MineSalt.s.sol` derives its offset the way `Deploy.s.sol` does. The deployment below is on a
re-mined salt whose `predictedToken` returns empty from `eth_getCode`.

---

## Status

- **279 tests pass across 37 suites.**
- **BSC mainnet redeployed and carries exactly this source.** Every beacon's `owner()` is Flap's
  Guardian, every beacon's `implementation()` matches the manifest, and every proxy's ERC-1967
  beacon slot points at its own beacon — all read from the chain. Each of the seven implementations
  is **byte-for-byte identical** to its local artifact: with the immutables converted to storage
  there are no immutable slots left, so this is an exact comparison rather than "differences fall
  inside declared slots". `tournament.curator()` returns the deployer; deployer, curator and salvage
  are one key.
- **BSC testnet: nothing of ours deployed.** The chain-97 manifest records a deploy whose
  transactions never landed. `eth_getCode` is empty for every contract that manifest says *we*
  deployed; the one address in it that does hold code is the third-party ERC-8004 registry we read
  (`script/Deploy.s.sol:70`).
- **No token is launched.** `SKIP_TOKEN=true`; `taxToken` and `flapVault` are both the zero address
  in `deployments/56-latest.json`, and `predictedToken` `0x0570411CACDc4dD29DE229321EFb75153e907777` is empty on chain.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | not deployed | `0x0dEcCDEb5816773Ce962e4F6b4f74fa0de7E9663` |
| `Tournament` | not deployed | `0xC1707fDDc579339061DC47Edbd912687903EC916` |
| `AssayVault` (approve this) | not deployed | `0x720F48484Bfe5D22BAe679c531B53C70607A62dD` |
| `AgentRoster` | not deployed | `0xdef12257719A1f36072fa8132673bb65CC4A370B` |
| `TaskGenerator` | not deployed | `0x1660623253ceCd17d4db986563Bd8Ac65D1824dC` |
| `PriceGuard` | not deployed | `0xD33451cD95A8b513a69227e4cB53d391de5895Fb` |
| Curator (`withdrawUnconverted` pays) | — | `0x9E591947199091D4ff23DCF9Ab1C88576bd550e8` |
| Beacon owner (upgrade authority) | — | `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b` |
| Tax token | — | not launched |
