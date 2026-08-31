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

<!-- deployments:start -->

## BNB Smart Chain mainnet (56)

| | |
|---|---|
| Factory (the contract Flap audits) | `0x988D8810244c556F69BA93dE977aE1Cc46f250Ac` |
| Flap vault | not deployed |
| Tax token | not launched — the factory is what Flap audits, and a launch claims an address permanently |
| Tournament | `0xcB51E301ba9F0590BeE55873BF1912ec21503CF5` |
| Custody ledger | `0x51A895568dDea50f42F6caf6531078748f343A14` |
| Roster | `0x61e4ab7e139894cdA9C5d88eF02B9F48FdF3092F` |
| Deployer / curator | `0x8F1054643baF32fe6c06C5CA9B3a990197883D8b` |

## BNB Smart Chain testnet (97) — the proof deployment

| | |
|---|---|
| Factory (the contract Flap audits) | `0xE2C9f7D6AEbAc75B8A34741048F4f5Ab2cB22b51` |
| Flap vault | not deployed |
| Tax token | not launched — the factory is what Flap audits, and a launch claims an address permanently |
| Tournament | `0xBc5ee6d9C525E8fbe92282609504818eb909316b` |
| Custody ledger | `0x7B92FbA57c5Cc83b655610C7906cA15251decDeA` |
| Roster | `0xE912813aCFe80A4D545d9457C894568aDC3f6D2b` |
| Deployer / curator | `0x8F1054643baF32fe6c06C5CA9B3a990197883D8b` |

<!-- deployments:end -->

The token collects 200 bps each way. The conversion path was exercised end to end with Flap's
Trigger Service submitting the swap rather than us.

## Two things a reviewer found, and what they turned into

Pre-audit review raised the size of a single conversion against the BTCB pair. The reported
finding was that a large balance would fail to convert, because `MAX_ENDOW_SLIPPAGE_BPS` caps
impact at 3%. Measured against the live pool, the opposite was true and worse: the bound was
compared against `quote(bnbAmount)`, which already prices the impact of that size, so it could
never object. Two thousand BNB in one call landed 47.6% below the untouched price and was
accepted. `_requireWithinImpact` now measures against `spotUnitPrice()` — what the pool pays for
an amount too small to move it — and `maxConvertible()` publishes the largest size that clears,
binary-searched against the pool as it is rather than written into a document that goes stale.

Fixing it pushed the factory to 25,398 bytes, past EIP-170, and a broadcast is what said so —
after the tournament beside it had already landed and been paid for. `test/CodeSize.t.sol` now
deploys each contract and fails while there is still less than a kilobyte of headroom, rather
than at the one moment being wrong costs money.

## The two packages

| Package | Contents | Step |
|---|---|---|
| `dist/assay-vault-audit.zip` | Contracts at the archive root, flattened single files, the standard JSON that reproduces the deployed bytecode, the self-check, the whole test suite, and a verifier that checks the address against the chain | 6 — contract audit |
| `dist/assay-vault-ui.zip` | The four-file Vault UI source package, format 6, with its QA report | 7 — after the audit passes |
