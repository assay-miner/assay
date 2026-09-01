# Flap Vault Interaction Risk Report — response

Project: ASSAY (`AssayFlapVault`) · Report 2026-09-01 10:05:41 UTC · Response commit `21378a7`

Both findings accepted and fixed.

---

## Finding 1 — SYS-REQ-LITERAL-ERRORS

**Status: [x] TP  [ ] FP  [ ] By Design  [ ] Acknowledged**

Fixed. All 47 custom errors removed and all 65 revert sites converted to
`require(condition, "English / 中文")`:

| Contract | Errors | Revert sites |
|---|---|---|
| `src/Tournament.sol` | 20 | 25 |
| `src/AgentRoster.sol` | 10 | 13 |
| `src/AssayVault.sol` | 10 | 19 |
| `src/Crucible.sol` | 4 | 4 |
| `src/TaskGenerator.sol` | 2 | 2 |
| `src/PriceGuard.sol` | 1 | 1 |
| `src/AssayFlapVault.sol` | 0 | 1 standalone `revert(unicode"…")` |
| **Total** | **47** | **65** |

The standalone `revert(unicode"Unsupported chain / 不支持该链")` in the `AssayFlapVault`
constructor became a positive assertion after the chain branch.

We had wrongly read the rule as applying to the vault contract only, on the reasoning that the
vault is what Flap's UI renders. It applies to any revert a user can reach, and every listed
contract is on a user path: enrolling calls `AgentRoster`, committing and revealing call
`Tournament`.

**Stated plainly:** this conversion loses the error arguments.
`InsufficientAccount(account, have, want)` is now
`require(have >= amount, unicode"Account is short / 账户余额不足")` and no longer carries the two
amounts. We read that as the rule's intent — a message the user can read beats a value they cannot
decode — but it is a real loss of debugging detail, flagged here rather than left to be found.

**Verify:**

```
grep -rn '^\s*error [A-Z]' src/*.sol           # 0 matches
grep -rn 'revert [A-Z]\|revert(' src/*.sol     # 0 matches
```

---

## Finding 2 — SYS-REQ-MULTILANG

**Status: [x] TP  [ ] FP  [ ] By Design  [ ] Acknowledged**

Fixed. Both `description()` banners are bilingual now.

`src/AssayFlapVault.sol`:

- `No task yet / 尚未发布任务`
- `Tax unconverted / 税款待兑换`
- `Bounty live / 赏金进行中`
- `Bounties collected / 赏金已领取`

`src/Tournament.sol`:

- `No task posted yet. / 尚未发布任务。`
- `A task is open. Commitments are being taken. / 任务进行中，正在接受提交承诺。`
- `Commitments are closed. Submissions are being revealed and assayed. / 承诺已截止，正在揭示并计量提交。`
- `The latest task is settled. Winners may claim. / 最新一期已结算，获胜者可领取。`

**Why the vault's banners are shorter than the tournament's:** the factory embeds the vault's
creation code, and adding the Chinese left only 861 bytes under EIP-170. The obvious remedy —
moving `vaultUISchema()` out, at 7,015 bytes the largest single item in the vault — is not
available: `VaultBaseV2` declares it `public pure virtual`, and a `pure` override cannot call an
external contract. So the vault's banners were tightened instead; each still names its state in
both languages. `Tournament` deploys standalone and keeps the full sentences.

Margin after the change: factory **1,055** bytes, `Tournament` **3,034** bytes.

---

## Status

- 215 tests pass across 32 suites.
- 55 test assertions moved from `vm.expectRevert(Contract.Error.selector)` and
  `vm.expectRevert(bytes4(keccak256("Error()")))` to `vm.expectRevert(bytes(unicode"… / …"))`, so
  each now asserts the exact string a user sees rather than a selector.
- Both chains redeployed so the deployed bytecode matches the packaged source; the packaging step
  verifies that byte for byte.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x2be2d3EA801f963eCDb3333D03dd3F5536162482` | `0xAa3EC76ACf14efb15C75fb9F01cb16F8A61F9C94` |
| `Tournament` | `0xb7c1A8ccfc95Cd0B7bEdd53228dC65d1a95Df44d` | `0x31A19fddE5ab164EA790ffcAc25CbeB65658c1d0` |
| Tax token | not launched | not launched |
