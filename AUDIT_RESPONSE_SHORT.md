# Flap Vault Interaction Risk Report

Generated: 2026-09-03 15:35:48 UTC

## Vault Security Rating
**Low**

Project: ASSAY (`AssayFlapVault`)

Accepted and fixed, extended to the one other method with the same shape.

---

## Risk Findings

### Finding 1: endow is presented to all users in vaultUISchema despite being Guardian-only
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** The README ("Where to look hardest") and the vault's own NatSpec state that `endow` is a Guardian-only escape hatch (`require(msg.sender == _getGuardian(), ...)`). However, `vaultUISchema()` lists `endow` (method index 4) as an ordinary write method with the friendly description "Add to the pool / 向池中注资" and no indication that it is restricted to the Guardian. A generic Flap UI renders every `isWriteMethod` entry as a callable button, so an ordinary user is shown `endow` as a normal action.
- **Vulnerable Code:**
  - `AssayFlapVault.vaultUISchema (method index 4 'endow')`
  - `AssayFlapVault.endow`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted. The description said what `endow` does and nothing about who may call it, and a generic renderer draws every `isWriteMethod` entry as an ordinary button. It now reads "Add to the pool (Guardian only) / 向池中注资(仅限守护者)".

The schema format has no field for this — `VaultMethodSchema` carries a name, a description, typed inputs and outputs, and an approval list, but nothing marking a method as role-restricted. The description is the only place the words can live, so that is where they went.

**Extended to the one other method with the same shape**, since the finding names a pattern, not just one button. `postTask` is not Guardian-only, but it is restricted the same way for the audience most likely to be confused by it: the curator and Guardian may post at any time, while anyone else may post only in the gap between epochs and only for a short window. Its description named the action and said nothing about that asymmetry either. It now reads "Publish a task (open window only for non-curators) / 发布一个任务(非策展方仅限开放窗口期)".

**Where we stopped, and why.** Every other write method — `collect`, `sponsor`, `triggerConversion`, `withdrawUnconverted`, `reclaimBounty`, `commit`, `reveal`, `claim` — is open to any caller; what can make them revert is the state of a task or a request, not who is asking. That is the ordinary shape of a dApp button that isn't ready yet, not an account being told it holds a permission it does not, and it is not what this finding is about. Extending the label pattern to every state-dependent revert would turn every description into a list of preconditions and push two contracts that are already tight on EIP-170 margin closer to it for a distinction the finding doesn't ask for.

**Tested, not just written.** `test_RestrictedActionsSaySoInTheirLabel` asserts `endow`'s description contains "Guardian"; `test_PostTaskWarnsNonCuratorsOfTheOpenWindow` asserts `postTask`'s contains "non-curator". Both were confirmed by reverting the description text and watching the matching test fail and nothing else — the schema-drift pattern this repository has hit before is a sentence changing back without anything noticing, so this is written as an assertion rather than left as a fact stated once in a commit message.

---

## Status

- Both new assertions were confirmed by reverting the description text and watching only the
  matching test fail.
- No token has been launched on either chain.
- **BSC mainnet carries the current code; BSC testnet is behind.** The testnet deploy failed for
  gas — the public BNB testnet faucet is out of funds — so that address still runs an earlier
  revision. The bytecode check in our packaging step is against mainnet and it passes.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x6b220DACd22467e837249344399A5d52951Ae264` | `0xF062f9B72778294819486c68CbceAcbea8F9078a` |
| `Tournament` | `0x2d14990a90640435CdbE13BA80e9c57e81d9c5dd` | `0x5c9e36e588859516007e06de145Bde6f92bF883A` |
| Tax token | not launched | not launched |
