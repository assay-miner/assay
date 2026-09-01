# Flap Vault Interaction Risk Report

Generated: 2026-09-01 16:41:21 UTC

## Vault Security Rating
**High**

Project: ASSAY (`AssayFlapVault`)

Both findings are accepted and fixed. They share one cause: the schema is the only part of these
contracts that nothing executes — no test calls a fieldType or reads a label — so it drifts
silently. Our existing gate for that class compared field names and not types, which is why both
reached you. It compares types and labels now.

---

## Risk Findings

### Finding 1: Tournament vaultUISchema declares postTask parameter types that do not match the actual function signature (SYS-REQ-INHERITANCE)
- **Severity:** High
- **Confidence:** High
- **Detected by:** attacker_review, rule_review

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed, and the reason it survived is worth reporting with it. Every type the finding names was wrong: `inputs` declared "bytes" against `bytes[]`, `expected` "bytes32" against `bytes32[]`, `gasCap` "uint256" against `uint32`, `pot` "uint256" against `uint128`, and `commitEnd`/`revealEnd` "time" against `uint64` — IVaultSchemasV1 defines "time" as an alias whose ABI encoding is identical to uint256, so those two are mismatches as well. A schema-following UI would have computed `postTask(bytes,bytes32,bytes,uint256,uint256,uint256,uint256)` and called a function that does not exist. The schema now declares the real ABI types.

`commitEnd` and `revealEnd` therefore lose their date-picker rendering, because "time" is defined only as a uint256 alias and these parameters are `uint64`. We chose an invokable method over a nicer input widget rather than widening the signature, since the packing of those two fields is deliberate.

We already had a gate for exactly this class — `tools/check-schema.mjs`, written after an earlier round caught `postTask` describing a parameter that no longer existed. It compared only the field NAMES. Every name here was correct, so the gate stayed green while the types drifted, which is why this reached you. It now derives the ABI type from each declared fieldType, applies the documented "time" → uint256 alias, and prints the selector a schema-following UI would call so a mismatch is visible as the wrong function. Run against the code you reviewed it reports exactly the six mismatches in this finding and nothing else.


### Finding 2: AssayFlapVault vaultUISchema contains single-language UI strings while the contract establishes bilingual intent (SYS-REQ-MULTILANG)
- **Severity:** High
- **Confidence:** High
- **Detected by:** rule_review

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed. All 16 labels are bilingual: the English-only ones ("Miner", "Skip", "Page size", "Task", "BTCB bounty", "Paid", "Scorers") now carry a Chinese half, and the four that repeated the same token on both sides of the separator ("BTCB / BTCB", "BNB / BNB") are now "Amount / 数量", which names the field rather than the unit.

The same gate was extended to cover this, since the two findings come from one blind spot — nothing in a test suite executes a schema label any more than it executes a schema type. `tools/check-schema.mjs` now rejects a label with no separator, a label whose two halves are identical, and a label with no CJK after the separator. That last check is what catches the "BTCB / BTCB" shape, which passes a naive test for the separator and is precisely what the rule prohibits.

The gate found 22 problems in total across both findings, the same set you reported and no others.

Shortening some labels was necessary rather than cosmetic: the factory embeds the vault's creation code, and the added Chinese pushed it to 410 bytes under EIP-170, below the margin our CodeSize test requires. Labels were tightened to "Bounty / 赏金", "Scorers / 得分者", "Amount / 数量" and "Paid / 已付", restoring the margin to 537 bytes while keeping both languages on every field. We want to flag that headroom directly: `vaultUISchema()` is about 7KB and cannot be moved out of the vault, because VaultBaseV2 declares it `public pure virtual` and a `pure` override cannot call an external contract. The next change of any size needs a structural answer, not more shortening.

---

## Status

- `node tools/check-schema.mjs` reports every write method's schema matching its ABI type and
  every label bilingual.
- Both chains redeployed from this source, so the deployed bytecode matches the packaged source.
- No token has been launched on either chain.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x31A19fddE5ab164EA790ffcAc25CbeB65658c1d0` | `0xFC554b1019A25Bb06472AcC29E0682B8fC337369` |
| `Tournament` | `0x9835c808D621f892C512DA34B8F27009924044D3` | `0x20b12D32f64c2e60a25E6E6828fF0AC39ee42d25` |
| Tax token | not launched | not launched |
