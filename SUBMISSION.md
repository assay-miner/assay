# Flap submission package — ASSAY

Against Flap's developer integration guide, step by step. Everything marked **ready** is in this
repository and reproducible; everything marked **blocked** needs one thing, and it is the same
thing every time.

---

## 1. Reference the example repository — **done**

`FlapVaultExample` and `src/FreeCoinBeacon.sol` were read before this pass, not after. Two
things were taken from them directly rather than derived: the base contracts under
`src/flap/` are Flap's own, unmodified, and the forked-integration-test shape in
`test/FreeCoinBeacon.mainnet.t.sol` is the shape `test/FlapSpec.t.sol` follows.

## 2. Confirm the proposal — **owner's call**

Worth doing before the audit spend, because two design points are ones Flap may have an opinion
on and both are cheaper to change now than after:

- **The factory takes no commission.** The token launches at 200 bps each way, so Rule 002 puts it in the `msg.value * 6 / taxRateBps` tier — a recommended 3%.
  We take zero and put all of it into bounties. Rule 002 asks for a justification when the
  recommendation is not followed; ours is in `SELF_CHECK.md` (L-02).
- **`endow` is curator-gated and performs a swap.** See M-02 in the same report. There is a
  permissionless alternative; it trades one risk for another and an outside opinion is worth
  having before committing.

## 3. Basic self-check — **done, clean**

`flap-vault-spec-checker` was run against both contracts. Report: [`SELF_CHECK.md`](SELF_CHECK.md).

- Critical: 0 · High: 0 · Medium: 2 · Low: 3 · Info: 6
- Every mandatory rule passes. Both Mediums are disclosures, not defects: one is the Guardian
  authority Rule 009 itself requires, one is a residual sandwich window that no in-contract
  bound fully closes.
- Five violations were found and fixed during the pass: custom errors (UI-01), missing emergency
  controls (Rule 009), an unbounded slippage floor on a privileged swap (Rule 003), missing test
  coverage (Rule 006), and reentrancy ordering in `sponsor`.

Measured, not estimated:

| | |
|---|---|
| `receive()` gas | **12,988** — 1.3% of the 1,000,000 ceiling |
| `AssayFlapVault` runtime | 16,464 bytes |
| `AssayFlapFactory` runtime | 19,526 bytes |

## 4. Integration tests — **done**

`forge test` — the audit archive states its own test and suite counts, measured by the script
that builds it from the tests inside it. An earlier revision of this file quoted a figure for the
repository while the archive shipped four of its suites; a reviewer counted 33 against a claimed
103 and was right to stop. The archive now carries the whole suite and derives the number.

| Suite | Covers |
|---|---|
| `test/FlapSpec.t.sol` (13, forked 97) | Every item Rule 006 lists: `receive()` gas, Guardian access, the escape hatch's exclusivity, `description()` moving with state, schema shape and field vocabulary, `vaultDataSchema()`, `newVault()` portal guard, the slippage bound, and post-drain solvency |
| `test/RewardAsset.t.sol` (12, forked 56) | The economics against the real market: conversion, the floor holding, both revert paths, the miner paid in BTCB, sponsorship, double-collect |
| `test/FlapGate.t.sol` (4, forked 56) | An unregistered factory launching through the real VaultPortal |
| `test/FlapRender.t.sol` (4, forked 56) | The schema holds against the real ABI, and survives Flap's renderer filters |
| `tools/rehearse.sh` | The whole protocol end to end against a fork: launch, tax, task, mine, reveal, claim, collect |

## 5. Test on BNB testnet — **blocked: needs tBNB**

Everything is rehearsed on a fork of chain 97 and reproducible in 33 seconds:

```bash
anvil --fork-url https://bsc-testnet-rpc.publicnode.com --port 8546 --chain-id 97 --silent
./tools/rehearse.sh
```

For the real testnet, three commands and a funded key:

```bash
CHAIN_ID=97 PRIVATE_KEY=0x… ./launch   # stack + taxed token + vault, addresses chained forward
CHAIN_ID=97 PRIVATE_KEY=0x… ./post     # posts a task and converts the tax behind it
CHAIN_ID=97 PRIVATE_KEY=0x… ./exit     # takes back everything recoverable, immediately
```

## 6. Audit and the low-risk badge — **owner's call: 0.5 BNB per factory**

Optional. Without it the vault launches and renders, carrying `UNVERIFIED` and with write
methods behind Flap's countdown gate. The self-check above is what a partner firm would start
from, and M-02 is the finding worth their time.

## 7. Custom interface — **built, submittable after the audit**

[`flap-ui/`](flap-ui/) — four files, validated by the template's own `vault:check` with zero
blocking issues, and rendered against live fork data inside Flap's preview shell.

`flap-ui/README.md` records what could not cross the runtime boundary rather than glossing it:
the display faces load from a font host the sandbox cannot reach, and the paper and gold-etch
grounds are image files admissible only through a pinned IPFS CID. The gold is a gradient and the
crucible is drawn.

Its one remaining blocking check is the same blocker as step 5: `manifest.match.bindings` must
resolve to a real deployed factory and a real `…7777` token on chain 97, and the addresses in it
are from a fork rehearsal.

---

## What is actually outstanding

**One thing: a funded key.** Steps 5 and 7 both need a real deployment; step 6 needs 0.5 BNB if
the badge is wanted. Nothing else in this list is waiting on work.

Repository at `abfa000`.


---

# Deployment state — 2026-08-28

## BNB Smart Chain mainnet (56)

| | |
|---|---|
| Factory | `0x02297d985f67bb6449E12F2447Eb07F708161Dc0` |
| Tournament | `0xB8B08CBbd9EB8ca4569a6dBFDA2af25fCc8Ae7A1` |
| Custody ledger | `0x336Bdb2528d31d45C35a90D585DDA8244bB62e13` |
| Roster | `0x50861700f69aB37Ea9c8227d99D49685cD7f42B7` |
| ASSAY token | `0x4c25b289440dd839c667589503e18EcDB55b0B5E` |
| Tax token | not launched — Flap audits the factory, and launching claims a name permanently |

## BNB Smart Chain testnet (97) — the proof deployment

| | |
|---|---|
| Factory | `0x537d8D999bcbfBe8Bd4342049151B726146Cd910` |
| Tax token | `0xdac353C10913d6e6EACa0421ca11c1d57c027777` |
| Flap vault | `0x46146690c1F66184ad999Aa8B503DC4c6049e11e` |
| Tournament | `0x420FCb2D8Db6EEB37Af775825C07D4d495AC67E8` |

The conversion path was exercised end to end on this deployment, with Flap's Trigger Service
submitting the swap rather than us. The tournament was run at the shipped difficulty: eight
vectors, a baseline of 1264, a miner scoring 1.0260x at 1232 gas.

## What an empty round costs

Nothing but gas, and that is a deliberate change. `withdrawUnconverted` returns tax that was
never placed behind a task, and `reclaimBounty` returns a bounty nobody won once the tournament's
own reveal window has closed. Both were missing, and their absence was the dangerous half of a
five-minute cadence: most windows draw nobody, and every one of them used to lock its tax
permanently with only Flap's Guardian able to move it.

Neither can reach money a miner earned. `reclaimBounty` takes the tournament's claim window as
its gate, so while a score exists and that window is open the curator waits; `withdrawUnconverted`
moves native value only, which by construction is the unconverted part. `test/NotStuck.t.sol`
proves both by breaking them.

## The two packages

| Package | Contents | Step |
|---|---|---|
| `dist/assay-vault-audit.zip` | Contracts at the archive root, flattened single files, the standard JSON that reproduces the deployed bytecode, the self-check, the whole test suite, and a verifier that checks the address against the chain | 6 — contract audit |
| `dist/assay-vault-ui.zip` | The four-file Vault UI source package, format 6, with its QA report | 7 — after the audit passes |

Both archives state their own measured figures. The audit archive is built by a script that runs
the tests going into it and writes that number itself, then extracts the result into an empty
directory, builds it with pinned dependencies, runs it again, and refuses to ship if the stated
count and the measured one disagree.
