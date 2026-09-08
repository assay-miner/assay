# Flap Vault Interaction Risk Report — response

Generated: 2026-09-07 · Project: ASSAY (`AssayFlapVault`)

Both findings are real and both are now fixed. Finding 1 was Acknowledged in an earlier round; the
function it concerns has since been removed at your reviewer's request, so the disposition changed
with the code rather than with an argument.

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

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed by removal. `withdrawUnconverted` no longer exists: your later review asked that vault funds never move to an address the project controls, so the function this finding is about — the only path that sent vault value to a project address — was deleted, along with the vault's `curator` field and its schema entry. There is nothing left for a griefer to hold shut.

**What replaced it.** Nothing. Idle native tax stays in the vault, `triggerConversion` turns it into
BTCB in `rewardPool`, `fundTaskFromPool` places it behind the drawn task, and miners take it with
`collect`. The only way value now leaves this vault to anybody who is not a scored miner is Flap's
Guardian, through `emergencyWithdrawNative` / `emergencyWithdrawToken`.

**One bound worth stating plainly.** `_arm` declines to convert while free tax is at or below
`FEE_COVER_MULTIPLE * fee` — ten times the scheduler's fee. Below that the balance waits for more
tax to push it over the threshold rather than converting; it is a working balance, not a permanently
stranded one, and at end of life it is the Guardian's to sweep. That is the arrangement your review
asked for, stated so it is not discovered later.

**Verified on chain, not just in source.** In the deployed implementation
(`0xC310Ae2e2235797Daf0390249f2e5db1888a64bB`): the selector `0x560952f4` does not appear, `curator()` does not appear, and the
`UnconvertedWithdrawn` topic does not appear.

**The tests kept their coverage rather than losing it.** The suites that exercised this function now
call it by raw selector and assert the call fails, so the removal is a property under test — the
count of schema methods alone would not catch it coming back, and one assertion checks for that
method by name. `test/WithdrawalFreeze.t.sol`, whose entire subject was the freeze, asserts instead
that the value has no path out except to miners and the Guardian.

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

## Requested change — no vault funds move to a project-controlled address

> *Funds in the vault should not be transferred to any centralized address. Ideally, they should
> remain in the vault and continue to be used for users as intended. If an emergency withdrawal is
> necessary, it should be carried out through the Flap Guardian.*

Done, by deletion rather than by restriction. Removed from `AssayFlapVault` <!-- check-symbols:allow -->:

- `withdrawUnconverted(uint256)` — removed; it was the only function that sent vault value to a project address
- the `curator` storage variable, and its parameter in `initialize`
- the `UnconvertedWithdrawn` event, removed with it
- its `vaultUISchema()` entry, removed too — eleven methods now, five of them writes

`AssayFlapFactory.newVault` no longer passes Flap's `creator` into the vault. That argument existed
only to become `curator`, so the launcher now supplies nothing the vault stores — the two references
it holds, its tournament and its price guard, are both the factory's.

`script/Exit.s.sol`, the project's own recovery script, lost its unconverted-tax leg with it. What
it still recovers is ASSAY the project posted as a task pot and nobody won, through
`Tournament.reclaim` — that was never vault tax.

Confirmed against the deployed implementation `0xC310Ae2e2235797Daf0390249f2e5db1888a64bB`: the selector `0x560952f4`,
`curator()`, and the `UnconvertedWithdrawn` topic are all absent from its runtime.

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
| `Tournament` | `0xfc50F53B744270C41eC9AD9f7562aC6A9117cf93` | `0xF33fcE0A7540Ac3BA09855f653531a475688bA45` | `0x8ba7070308B8fffff45143A66355d36757e77569` |
| `AssayVault` | `0xd484dFd9b1c53f13263eCa03A812A02559BD054F` | `0x6208d9ec11b1d8E0e26f809E7a7151630E39dc0C` | `0x7bD87282B751A2Cbd256c2C62ab4451665d3D3C1` |
| `AgentRoster` | `0xedB1D8E93A8Ad072D251E2512F14cF6F88DfDE49` | `0x9F700057F8D0df6e0B87F9927A650DB3D657Bd9A` | `0xb40cc0b5337018381bCb3766cE36f034a01638F3` |
| `PriceGuard` | `0x375efbF542CbD6B317517463AE1005d64E925505` | `0x81D93413dB9807C9AfeeC24526768a41e9452267` | `0x284C15741a7AdcB5852b17D41276ab6753E47754` |
| `TaskGenerator` | `0xe73D5A1B8C5fF18C7066F3e44abeF0430705994A` | `0x21A97Dd5bCE45E838c674ff7C5f4A7aF51906d2a` | `0xC8A8fBad237a3a969cFcb29892fb1BEC40C7e01a` |
| `AssayFlapFactory` | `0x116670f9Fc9B3D02BA8BDEc7a04b27F504c99F3F` | `0x5d13D641e5a819C290eFFD293706FbeB12D6Ed82` | `0x0AEbD4A79c652F516b96fbe79D748A19039D006F` |
| `AssayFlapVault` | one per token, minted by the factory | `0x1837214d5B5b4FeFef371f26E72E87218A08e3d2` | `0xC310Ae2e2235797Daf0390249f2e5db1888a64bB` |

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
| `AssayFlapFactory` | not deployed | `0x116670f9Fc9B3D02BA8BDEc7a04b27F504c99F3F` |
| `Tournament` | not deployed | `0xfc50F53B744270C41eC9AD9f7562aC6A9117cf93` |
| `AssayVault` (approve this) | not deployed | `0xd484dFd9b1c53f13263eCa03A812A02559BD054F` |
| `AgentRoster` | not deployed | `0xedB1D8E93A8Ad072D251E2512F14cF6F88DfDE49` |
| `TaskGenerator` | not deployed | `0xe73D5A1B8C5fF18C7066F3e44abeF0430705994A` |
| `PriceGuard` | not deployed | `0x375efbF542CbD6B317517463AE1005d64E925505` |
| Curator (posts on the curated lane) | — | `0x9E591947199091D4ff23DCF9Ab1C88576bd550e8` |
| Beacon owner (upgrade authority) | — | `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b` |
| Tax token | — | not launched |
