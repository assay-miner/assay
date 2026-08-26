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

- Critical: 0 · High: 0 · Medium: 2 · Low: 3 · Info: 3
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

`forge test` — **103 passing, 0 failing**, across 12 suites. Six fork real BSC state.

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

# Deployment state — 2026-08-26

## BNB Smart Chain mainnet (56)

| | |
|---|---|
| Factory | `0x143Ef060b34b1E69100A9948dD908AC9E154d082` |
| Tournament | `0xc8E92eD2Bcf5E6cDd3daE12ab78c06Fb850acC11` |
| Custody vault | `0x6E2EDeF560323fc891Ff0FFf10d8F5697E26DF06` |
| Roster | `0xA8d6D66F6E1C4bD4F9DA7D7d7EE894aa97C9e275` |
| ASSAY token | `0x016F7c19A44ee25B5dA2F32049C1bA9C8A0382F1` |
| Tax token | not launched — see below |

The deployed factory runtime is byte-for-byte the compiled artifact once its two immutable slots
are blanked; both hold the tournament address. `verify-onchain.mjs` in the audit package checks it.

No tax token has been launched on mainnet. Flap audits the factory and their guide puts that
before the UI submission; launching claims the name permanently and opens a real market, so it is
a separate decision from deploying the contract that gets audited.

## BNB Smart Chain testnet (97) — the proof deployment

| | |
|---|---|
| Factory | `0x525A3E57cdFE7bee43AA81670329024aa5d21Bd3` |
| Tax token | `0xDf87C67E327f71646a704c38ba9f963Fca387777` |
| Flap vault | `0xbc9A5D01cEF599E405E37dDa672d044a695880b0` |
| Tournament | `0xc8E92eD2Bcf5E6cDd3daE12ab78c06Fb850acC11` |

Task 1 is live with a real bounty: 0.05 tBNB of tax was converted through PancakeSwap to
**0.025318 BTCB** and placed behind it. The vault reports `solvent() == true`.

## The two packages

| Package | Contents | Step |
|---|---|---|
| `dist/assay-vault-audit.zip` | Contracts, the standard JSON that reproduces the deployed bytecode, the self-check, the forked integration tests, and a verifier that checks the address against the chain | 6 — contract audit |
| `dist/assay-vault-ui.zip` | The four-file Vault UI source package, format 6, with its QA report | 7 — after the audit passes |

The UI package binds chain 97 (our factory plus our own `…7777` proof token) and chain 56 (the
mainnet factory), which is the shape the template documents for a factory-scoped mainnet launch.
`vault:check` reports zero issues, `vault:e2e` passes on all three viewports with
`tokenPolicy: "testnet"`, and `vault:verify-package` confirms the archive.

One thing worth stating plainly about that E2E pass: it is a layout and state conformance gate,
run with host token/tax/vault data deliberately unavailable, so it never displays live figures.
It was checked separately, through the preview route against the real chain-97 deployment, that
the component renders the real bounty, the real task and the real phase.
