# Flap Vault Interaction Risk Report

Generated: 2026-09-01 16:41:21 UTC

## Vault Security Rating
**High**

Project: ASSAY (`AssayFlapVault`)

All seven findings are accepted. Findings 1 and 2 were answered in the previous submission and
are repeated here so this file stands alone.

---

## Risk Findings

### Finding 1: Tournament vaultUISchema declares postTask parameter types that do not match the actual function signature (SYS-REQ-INHERITANCE)
- **Severity:** High
- **Confidence:** High
- **Detected by:** attacker_review, rule_review
- **Description:** Tournament.vaultUISchema() describes the postTask write method with input field types that differ from the real postTask signature. The schema declares inputs as bytes and expected as bytes32 (single values), whereas the actual function takes bytes[] and bytes32[] arrays; it also declares gasCap/pot as uint256 where the actual types are uint32/uint128 and commitEnd/revealEnd as time (uint256) where the actual types are uint64. A generic Flap UI derives the ABI type string and function selector from these declared types, so a schema-following caller computes a selector for postTask(bytes,bytes32,bytes,uint256,uint64,uint256,uint256) instead of the real postTask(bytes[],bytes32[],bytes,uint32,uint64,uint64,uint128), and the postTask write method is uninvokable through the auto-generated UI. This violates SYS-REQ-INHERITANCE's schema-vs-signature consistency requirement.
- **Vulnerable Code:**
  - `src/Tournament.sol: vaultUISchema (method 6 postTask, inputs[0] "inputs" declared "bytes" vs actual bytes[])`
  - `src/Tournament.sol: vaultUISchema (method 6 postTask, inputs[1] "expected" declared "bytes32" vs actual bytes32[])`
  - `src/Tournament.sol: vaultUISchema (method 6 postTask, inputs[3] "gasCap" declared "uint256" vs actual uint32)`
  - `src/Tournament.sol: vaultUISchema (method 6 postTask, inputs[6] "pot" declared "uint256" vs actual uint128)`
  - `src/Tournament.sol: postTask signature`
  - `src/Tournament.sol: vaultUISchema (method 6 postTask)`
  - `src/Tournament.sol: postTask`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed. Every type named is now the real ABI type: `inputs` is `bytes[]`, `expected` is `bytes32[]`, `gasCap` is `uint32`, `pot` is `uint128`, and `commitEnd`/`revealEnd` are `uint64` instead of "time", which IVaultSchemasV1 lines 150-153 define as an alias encoding identically to uint256. `commitEnd` and `revealEnd` therefore lose their date-picker rendering; we chose an invokable method over a nicer widget rather than widening the signature, because the packing of those two fields is deliberate.

One reconciliation, which does not change the verdict: the description derives the schema selector as postTask(bytes,bytes32,bytes,uint256,uint64,uint256,uint256), with uint64 in the commitEnd position. Both commitEnd and revealEnd were declared "time", so a UI following the alias would derive uint256 for both. Either way the selector is wrong and the method is uninvokable. The Vulnerable Code list names four fields and the description adds commitEnd and revealEnd, which is the six our own check now reports.

Why it survived: tools/check-schema.mjs was written after an earlier round caught postTask describing a parameter that no longer existed, and it compared only field NAMES. Every name here was correct, so the gate stayed green while the types drifted. It now derives the ABI type from each fieldType, applies the documented "time" alias, and prints the selector a schema-following UI would call, so a mismatch reads as the wrong function rather than a list of types.


### Finding 2: AssayFlapVault vaultUISchema contains single-language UI strings while the contract establishes bilingual intent (SYS-REQ-MULTILANG)
- **Severity:** High
- **Confidence:** High
- **Detected by:** rule_review
- **Description:** The codebase establishes multi-language intent everywhere (all require() messages and most schema strings use the English / 中文 bilingual pattern). However, several user-facing strings returned by AssayFlapVault.vaultUISchema() are single-language English only, and several use the same language on both sides of the / separator (which the rule explicitly treats as non-compliant). This violates SYS-REQ-MULTILANG, under which every user-facing string must be bilingual once multi-language evidence exists.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: vaultUISchema getBounties input "Miner"`
  - `src/AssayFlapVault.sol: vaultUISchema getBounties input "Skip"`
  - `src/AssayFlapVault.sol: vaultUISchema getBounties input "Page size"`
  - `src/AssayFlapVault.sol: vaultUISchema getBounties output "Task"`
  - `src/AssayFlapVault.sol: vaultUISchema getBounties output "BTCB bounty"`
  - `src/AssayFlapVault.sol: vaultUISchema getBounties output "Paid"`
  - `src/AssayFlapVault.sol: vaultUISchema getBounties output "Scorers"`
  - `src/AssayFlapVault.sol: vaultUISchema collect input "Task"`
  - `src/AssayFlapVault.sol: vaultUISchema sponsor input "Task"`
  - `src/AssayFlapVault.sol: vaultUISchema reclaimBounty input "Task"`
  - `src/AssayFlapVault.sol: vaultUISchema collectable input "Task"`
  - `src/AssayFlapVault.sol: vaultUISchema collectable input "Miner"`
  - `src/AssayFlapVault.sol: vaultUISchema collectable output "BTCB / BTCB" (same language both sides)`
  - `src/AssayFlapVault.sol: vaultUISchema maxConvertible output "BNB / BNB" (same language both sides)`
  - `src/AssayFlapVault.sol: vaultUISchema quote input "BNB / BNB" (same language both sides)`
  - `src/AssayFlapVault.sol: vaultUISchema quote output "BTCB / BTCB" (same language both sides)`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed. All 16 labels are bilingual: the English-only ones ("Miner", "Skip", "Page size", "Task", "BTCB bounty", "Paid", "Scorers") now carry a Chinese half, and the four that repeated the same token on both sides ("BTCB / BTCB", "BNB / BNB") are now "Amount / 数量", naming the field rather than the unit.

The same gate was extended to cover labels, because both findings come from one blind spot: nothing in a test suite executes a schema label any more than it executes a schema type. check-schema.mjs now rejects a label with no separator, a label whose halves are identical, and a label with no CJK after the separator — that last check is what catches the "BTCB / BTCB" shape, which passes any naive test for the separator. Across both findings the gate reports 22 problems, the same set you listed and no others.

Shortening some labels was forced rather than stylistic. The factory embeds the vault's creation code, and the added Chinese put it 410 bytes under EIP-170, below the margin our CodeSize test requires. Tightening to "Bounty / 赏金", "Scorers / 得分者", "Amount / 数量" and "Paid / 已付" restored 537 bytes with both languages intact on every field. We want to flag that headroom directly: vaultUISchema() is about 7KB and cannot be moved out, because VaultBaseV2 declares it public pure virtual and a pure override cannot call an external contract.

### Finding 3: Self-arming conversion under-funds the scheduled swap by the scheduler fee, causing the trigger callback to revert and corrupting `reserved` accounting (COM-EXTERNAL-CALL-FAILURE)
- **Severity:** Medium
- **Confidence:** Medium
- **Detected by:** rule_review
- **Description:** In AssayFlapVault._arm, when invoked from the self-arming path inside trigger (with incoming == 0), the scheduled conversion amount is set to the full freeTax() value, while the Trigger Service fee is simultaneously paid out of the same native balance via requestTrigger{value: fee}. The fee is never subtracted from the amount that gets reserved and stored in scheduled[next].bnbAmount. As a result, after arming, reserved overstates the on-chain balance by fee (freeTax() collapses to 0), and when the scheduler later executes the callback, _convertToPool(s.bnbAmount) attempts swapExactETHForTokens{value: s.bnbAmount} with a value larger than the vault's actual balance. Absent additional tax arriving in the interim, this call reverts (you cannot forward more value than the contract holds), so the scheduled conversion can never execute and the request stays FAILED/retryable while the automatic conversion cadence stalls. The manual triggerConversion path is unaffected because the fee there is funded by msg.value and the excess refunded, keeping reserved == balance.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol:_arm`
  - `src/AssayFlapVault.sol:trigger`
  - `src/AssayFlapVault.sol:_convertToPool`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Correct in every particular, and already fixed — the analysis matches a bug we found and closed before this report was generated, so the code you reviewed is one commit behind. `_arm` now nets the fee out of the convertible amount on the self-arming path:

    if (incoming == 0) {
        if (amount <= fee) return 0;
        amount -= fee;
    }

`incoming == 0` identifies that path exactly, because `triggerConversion` requires `msg.value >= fee`. Measured under a deliberate re-break of the fix: armed 2.4e15 against a balance of 2.2e15, over by exactly one scheduler fee, and the callback then reverts inside swapExactETHForTokens.

Two notes for accuracy. Your reading that the manual path is unaffected is right and is why the fix is conditional rather than unconditional. And our first test for this was worthless — it funded the vault with twenty fees of slack, so over-reserving by one fee could not break the invariant, and deleting the entire fix left all twenty tests in that file green. It has been rewritten with no slack, asserting on the newly armed request rather than on cumulative `reserved`.


### Finding 4: `curator` documented as the party who may endow, but `endow` is Guardian-only
- **Severity:** Medium
- **Confidence:** High
- **Detected by:** doc_review
- **Description:** The NatSpec on the immutable state variable states: /// @notice Who may endow a task with accumulated BNB. Set at creation to the token's creator. address public immutable curator;. This documents the curator as the account permitted to call endow. The actual endow function begins with require(msg.sender == _getGuardian(), "Only the guardian / 仅限守护者");, so the curator can never call it. The curator is in fact only used as an authorized caller of cancelConversion and as the fixed destination of withdrawUnconverted.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: curator declaration NatSpec`
  - `src/AssayFlapVault.sol: endow()`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted, and the comment was the wrong half — the code is what we want. `endow` is the Guardian's alone deliberately: it is the direct, unscheduled conversion path, and putting it behind Flap rather than behind us is the point. The NatSpec was left over from a design where the curator did convert, and your description of what `curator` is actually for — authorised caller of `cancelConversion`, fixed destination of `withdrawUnconverted` — is exactly right and is now what the comment says.


### Finding 5: Permissionless fundTaskFromPool lets any caller move the entire reward pool onto a task of their choosing, letting a dominant scorer capture converted tax meant for the epoch's task
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** AssayFlapVault.fundTaskFromPool is callable by anyone and moves the WHOLE rewardPool (amount = rewardPool) onto whichever live task the caller names, one-shot per task. The only constraint is that the chosen task is still live (block.timestamp < revealEnd). Because the bounty is later split among scorers in proportion to their tournament score, a miner who is the sole or dominant scorer of some live task can call fundTaskFromPool on that task (e.g. after its commit window has closed and the entrant set is fixed) and then collect essentially the entire converted-tax pool, diverting it away from the epoch's intended task and from other honest miners competing on that task.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: fundTaskFromPool`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted and closed more tightly than the finding asks. Two gates now, because the finding names two separate things and only one of them was addressed by our earlier fix.

The example you give — funding after the commit window has closed, when the entrant set is fixed — was already blocked: the guard had moved from `revealEnd` to `commitEnd` in the previous round, so the pot is settled before the set of people dividing it is.

The general case was not, and it is the more important half: the caller still chose WHICH live task received the pool. `fundTaskFromPool` now requires the task to be the newest one:

    require(taskId == tournament.taskCount(), unicode"Not the current task / 非当前任务");

The epoch's task is always the newest, so there is no longer a choice to make and no other live task to divert to. Tested by posting two live tasks and funding the older one, which reverts; the newest still funds. Confirmed by deleting the guard and watching only that test fail.

We rated this higher than Low. Diverting the pool does not merely favour one miner over another — it moves converted tax onto a task whose scoring is already decided, which is the same shape as the capture in the previous round's finding 4.


### Finding 6: UI schema labels `endow` as "Fund a task" though it funds no task
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** In vaultUISchema, method index 4 is described as unicode"Fund a task (guardian) / 注资任务(守护者)" and takes only bnbAmount and minRewardOut — there is no taskId input. The endow implementation and its own NatSpec state it "Credits the pool ... and names no task" (it only increments rewardPool/endowed via _convertToPool). Assigning BTCB to a specific task requires a separate, permissionless fundTaskFromPool(taskId) call.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: vaultUISchema() method 4 (endow)`
  - `src/AssayFlapVault.sol: endow(), _convertToPool()`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted. The label described the old design, where converting and assigning were one call — which is precisely the coupling an earlier round asked us to break, because naming a task and naming an amount in the same action was where the curator's discretion lived. Splitting them left this label behind. It now reads `Add to the pool / 向池中注资`, which is what the method does; assigning to a task is `fundTaskFromPool`, and that is a separate entry in the same schema.


### Finding 7: Comment claims manual `triggerConversion` path is exempt from FEE_COVER_MULTIPLE, but code enforces it on both paths
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** In _arm, the comment above the guard states: "The manual path pays its own fee and is not bound by this; only the arming that spends tax is." However the guard if (amount <= fee * FEE_COVER_MULTIPLE) return 0; is applied unconditionally, with no branch distinguishing the manual entry (triggerConversion, incoming = msg.value) from the self-arming callback (incoming = 0). Thus a manual caller who pays their own fee is still blocked whenever the convertible window is <= fee * 10.
- **Vulnerable Code:**
  - `src/AssayFlapVault.sol: _arm()`
  - `src/AssayFlapVault.sol: triggerConversion()`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Accepted, and we fixed the comment rather than the code, which is worth explaining because the comment described a behaviour we no longer want.

The stated reasoning was about draining: the self-arming path buys the scheduler out of tax, so a window worth less than the fee costs more to convert than it converts, and at one epoch every five minutes that is 288 fees a day against a vault nobody is trading. A manual caller spends their own fee, so that reasoning genuinely does not reach them.

A second one does. Every conversion moves BNB from the side that returns to the curator for nothing into the side only a scoring miner can take out, and `triggerConversion` is permissionless. Exempting the manual path would let anyone convert dust all day at their own expense and strand this vault's tax behind a tournament indefinitely. The floor belongs on both paths; the comment now says so and says why.

---

## Status

- 221 tests across 32 suites; `node tools/check-schema.mjs` reports every write method's schema
  matching its ABI type and every label bilingual.
- Findings 4, 6 and 7 were documentation defects; the code was already what we intended and the
  comments were not. We have said which half was wrong in each case rather than quietly editing.
- Finding 5's second gate cost 192 bytes and put the factory 345 bytes under EIP-170. The vault's
  creation code has been moved out of the factory into `AssayVaultDeployer`, built by the factory
  in its constructor so it lands in creation code rather than runtime: the factory went from
  24,231 bytes to 2,637 and the binding headroom from 345 to 2,274.
- No token has been launched on either chain.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x20b12D32f64c2e60a25E6E6828fF0AC39ee42d25` | `0x86EAE44Fd8e0c65C09D935521473d347f74EE7cc` |
| `Tournament` | `0xFAc3CfD91791431A9274f9a315374d02c09bF9d5` | `0xEF9661759Dd7aa8C49C647E01e18D132493a452B` |
| Tax token | not launched | not launched |
