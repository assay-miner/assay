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

- **The factory takes no commission.** Rule 002 recommends 6% of tax revenue for a ≤1% tax rate.
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

# Deployment state — 2026-08-27

## BNB Smart Chain mainnet (56)

| | |
|---|---|
| Factory | `0x18a42C51E24a9cD8AFebA7317921cDF25BA9A2de` |
| Tournament | `0xe1393Fc841C65Eb8ed1368d58EB6AfFC5F229776` |
| Custody ledger | `0x5e338dc451F2999109616059d4142Ed7d8987Fd7` |
| Roster | `0x09Baf4d675161e8b8e69C95b35a8a60D96B282AF` |
| ASSAY token | `0xF6e9681b6252Cd4137B0646EB8f66489aeB4C0C2` |
| Tax token | not launched — Flap audits the factory, and launching claims a name permanently |

## BNB Smart Chain testnet (97) — the proof deployment

| | |
|---|---|
| Factory | `0xf656D56A3027220FF31Fb923D8Ac93ad57974D14` |
| Tax token | `0xCBca80E51F5504193f4C6cD3E6F338Fa8a6A7777` |
| Flap vault | `0x60de48f4C664B5807C615ca9Ea100A69564ea0dF` |
| Tournament | `0xc1Eb095F99144622a86143dea504a7906283719C` |

Task 1 carries a real bounty, placed there by Flap's Trigger Service rather than by us: 0.05 tBNB
of tax scheduled by the curator, executed by their backend as request `31132`, booked as
**0.025758 BTCB**. `solvent()` is true and `controllersFrozen` is true on both chains.

## The two packages

| Package | Contents | Step |
|---|---|---|
| `dist/assay-vault-audit.zip` | Contracts at the archive root, flattened single files, the standard JSON that reproduces the deployed bytecode, the self-check, the whole test suite, and a verifier that checks the address against the chain | 6 — contract audit |
| `dist/assay-vault-ui.zip` | The four-file Vault UI source package, format 6, with its QA report | 7 — after the audit passes |

Both archives state their own measured figures. The audit archive is built by a script that runs
the tests going into it and writes that number itself, then extracts the result into an empty
directory, builds it with pinned dependencies, runs it again and refuses to ship if the stated
count and the measured one disagree. An earlier archive shipped four hand-picked suites while
this file quoted the repository's total; a reviewer counted 33 against a documented 103 and was
right to stop there.
