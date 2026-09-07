# Flap Vault Interaction Risk Report — response

Generated: 2026-09-06 14:42:20 UTC · Project: ASSAY (`AssayFlapVault`)

Accepted without qualification. The comment described the design before finding 016, and 016's own
response said in as many words that the decision was being reversed — and then left the paragraph
asserting the old one. That is the third round in which prose here has been contradicted by the code
beside it, so the answer is a sweep rather than a sentence: **you named one, we found 38.**

---

## Risk Findings
### Finding 1: trigger() NatSpec claims "there is no try/catch" and that a failed conversion stays retryable, but the code catches the swap failure and consumes the request
- **Severity:** Medium
- **Confidence:** High
- **Detected by:** doc_review
- **Description:** The doc block at the top of `trigger(uint256 requestId)` states two things explicitly: (1) "The record is deleted before the swap. A revert undoes the deletion along with everything else, so a failed conversion leaves the request intact and retryable rather than consumed," and (2) "And there is no `try`/`catch`. Swallowing a failed fulfilment would let the service record the request as EXECUTED when nothing happened, and `retryTrigger` only works on a request marked FAILED. Reverting is what keeps the retry path alive." The actual implementation contradicts both: it deletes `scheduled[requestId]`, decrements `reserved`, and then wraps the conversion in `try this.convertForSelf(...) { } catch { emit ConversionFailed(...); }` (and additionally wraps `this.quote`, `priceGuard.impactBps`, and `this.rearmSelf` in try/catch). A failed swap therefore does NOT revert — the callback returns normally, the request is permanently consumed, and the vault re-arms a brand-new request instead of leaving the original marked FAILED for `retryTrigger`.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: trigger(uint256 requestId)`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Both sentences were false and are rewritten to state what the code does: four `try`/`catch` blocks, a failed conversion consumed rather than retryable, and `retryTrigger` given up deliberately. The finding is fixed; the sweep it triggered is below, because 37 more claims were wrong and that is the more useful half of this answer.

**The corrected paragraph says what was traded and why.** `retryTrigger` really is closed off — the
service marks a returning callback EXECUTED and only a FAILED one can be retried. It buys nothing
here: a retry re-attempts the same stored floor the market has already left behind, which is what
made the request unexecutable. Re-arming inside the same callback prices a new floor against the
market that just moved, so the recovery the retry existed for happens immediately and without the
service. Nothing is consumed in the sense that mattered — the BNB returns to free tax before the new
request is armed — and a failure is emitted rather than swallowed: `ConversionFailed` carries the
amount and the floor that was refused.

---

## The sweep: 38 stale claims across 14 files

Five lenses over prose against code, each candidate then attacked by an independent check that
defaults to refuting it. 44 raised, 6 refuted, 38 confirmed. An earlier round of this audit named 2
and the sweep found 21; this is the same shape and the same cause — a behaviour moves in one round
and a sentence written in an earlier one stays behind.

**The numbers were the worst of it, because they sat under a heading reading "Measured, not
estimated".**

| | stated | actual |
|---|---:|---:|
| `AssayFlapVault` runtime | 16,464 bytes | **22,062** |
| `AssayFlapFactory` runtime | 19,526 bytes | **2,637** |
| `vaultUISchema()` methods | 8 | **12** |
| `receive()` gas | 12,988 | **8,333** |
| `TriggerEndow` tests | 14 | **28** |

The factory figure is off by 7.4x because the `AssayVaultDeployer` split moved the vault's creation
code out of it and the number never followed. The gas figure was measured by nothing at all — it
appeared in that one document and nowhere else.

They are derived now, not typed. `tools/sync-submission.mjs` reads the runtime sizes out of the
compiled artifacts and counts the schema methods from source into a marked block, and the packager
refuses a stale one. The gas figure is a real test, `test_ReceiveStaysUnderTheGasCeiling`, and the
document cites the test instead of repeating a result.

**One claim was worse than stale, and it is a correction to something we told you.** SUBMISSION.md
called chain 97 "the proof deployment" and listed four addresses. `cast code` returns `0x` for every
one of them, on two independent endpoints. **Nothing is deployed on testnet.** We have been writing
"BSC testnet is behind" in these responses, which implies an older revision is running there; it is
not running at all. A testnet deploy failed for gas and the manifest was written anyway. That section
now says so, and the packager checks every address it ships for code.

**Two doc blocks had drifted onto the wrong function.** A `@notice` reading "Live one-line status,
polled by the UI as a banner" sat on `taskGates`, which returns four numbers; the `_convertToPool`
block sat on `convertForSelf`.

**Eight test comments described behaviour that changed under 024/025/026/027/028**, three of them
still asserting the poster whitelist those findings removed. A test comment that describes a
guarantee the code dropped is worse than a stale NatSpec — it reads as something still being checked.

**And the same wrong scoring formula turned up a third time.** README still carried
`baselineGas × 1e18 / gasUsed, capped at 32×` — the ratio form this contract deliberately does not
use — two rounds after we corrected it in both frontends. Score is the gas saved as a fraction of the
baseline, squared.

---

## Status

- 267 tests pass.
- **BSC mainnet redeployed and carries exactly this source.** Comments change the metadata hash, so a
  documentation round is a redeploy round here; we measured that rather than assumed it. Verified by
  call: every manifest address has code, `tournament.generator()` and the generator's `tournament()`
  point at each other, and `tournament.vault()` is the address a poster must approve.
- **A previous attempt at this deploy ran out of gas mid-broadcast and forge wrote the manifest
  anyway** — six addresses recorded, two with code. We restored the manifest rather than ship it,
  which is the same defect this round found in SUBMISSION.md and we were not going to commit it in
  the same round we reported it.
- **The manifest now records the curator.** It is the immutable destination `withdrawUnconverted`
  pays and it was never written down — invisible while it defaults to the deployer, which is exactly
  what it does here: one key is the deployer, the curator and the salvage address, asserted on chain
  by `tournament.curator()` rather than inferred from the script.
- **BSC testnet: nothing deployed.** See above.
- **No token is launched.** `SKIP_TOKEN=true`; `taxToken` is the zero address in
  `deployments/56-latest.json`. A rehearsal token from an earlier round exists on testnet at
  `0x769EfAbeFc18317A846A1E2BdeB831Ba659f7777`, which `test/DepositParity.t.sol` forks chain 97 to
  assert against on every run.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | not deployed | `0x6a70179bC27Dd2b49f6500E87c88c6d06f246001` |
| `Tournament` | not deployed | `0xcEA1b50ebfb4A1FB2E1f9e66bd9e030AD9A55E0c` |
| `AssayVault` (approve this) | not deployed | `0xb208f98e8008e1a84884040fa1cFBEE69eA47Ac7` |
| `TaskGenerator` | not deployed | `0x5Da50595E2d3327620A5a2A6551233b06E20714a` |
| Curator (`withdrawUnconverted` pays) | — | `0x9E591947199091D4ff23DCF9Ab1C88576bd550e8` |
| Tax token | rehearsal token, see above | not launched |
