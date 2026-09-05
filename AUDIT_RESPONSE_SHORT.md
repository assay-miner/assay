# Flap Vault Interaction Risk Report

Generated: 2026-09-05 12:19:15 UTC

## Vault Security Rating
**Low**

Project: ASSAY (`AssayFlapVault`)

Accepted. Every link in the description holds, we reproduced the revert, and the declaration is gone.
The reason it survived is that the test guarding it asserted the declaration's presence and each of
its fields — all correct — when the one thing that mattered is not a field at all.

---

## Risk Findings
### Finding 1: postTask pot deposit approval targets the wrong contract in Tournament.vaultUISchema
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** Tournament.postTask escrows its pot by calling AssayVault.deposit, which executes asset.safeTransferFrom(poster, AssayVault, pot). The token allowance therefore has to be granted to AssayVault. However, Tournament.vaultUISchema declares postTask with an ApproveAction ("taxToken", "pot"), and the Flap schema semantics fix the approve spender to the schema-owning contract itself (Tournament). A poster who follows the generated UI approves Tournament, but the actual pull is performed by AssayVault, so postTask reverts inside safeTransferFrom for any task created with a non-zero pot.
- **Vulnerable Code:**
  - `src/Tournament.sol: vaultUISchema (postTask ApproveAction)`
  - `src/Tournament.sol: postTask (vault.deposit call)`
  - `src/AssayVault.sol: deposit (asset.safeTransferFrom(from, address(this), amount))`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Confirmed link by link and reproduced: with an allowance to `Tournament`, `postTask` with a non-zero pot reverts; with an allowance to `vault()` it posts. The `ApproveAction` is removed and the description now names where the allowance goes, because the declaration cannot be made correct — `ApproveAction` has no spender field and `vaultUISchema` is `pure`.

**Verified against the code.** `Tournament.postTask:384` calls
`vault.deposit(KIND_POT, bytes32(taskId), msg.sender, pot)`, and `AssayVault.deposit:186` runs
`asset.safeTransferFrom(from, address(this), amount)`. So the allowance the escrow pulls against
belongs to `AssayVault`, and `IVaultSchemasV1`'s own workflow for an `ApproveAction` is steps 3 and 4:
`token.allowance(user, vault)` then `token.approve(vault, amount)`, where `vault` is the contract
whose schema it is. The two are different addresses on every deployment.

**Reproduced.** A fresh poster approving `Tournament` for the maximum and calling `postTask` with a
non-zero pot reverts inside the transfer. The same poster approving `tournament.vault()` posts. Both
halves are one test, so the claim and its remedy are asserted together rather than described.

**Why nothing operational hit it.** `script/PostTask.s.sol` has always approved
`tournament.vault()`, with a comment giving the reason — the vault pulls directly so the pot never
sits inside a logic contract even for one call. The defect was reachable only through a UI built from
the schema, which is exactly the surface this schema exists to describe.

**Fix — the declaration is removed and the description carries what it would have arranged:**

> Publish a task (open window only for non-curators). A non-zero pot needs an ASSAY allowance to the
> custody contract at `vault()`, not to this one.

**Declaring it correctly is not available, and we would rather say that than approximate it.**
`ApproveAction` is `{ tokenType, amountFieldName }` — there is no spender field — and
`vaultUISchema` is `pure`, so it cannot read `vault()` to put the address in the description either.
The remaining option would be to make `Tournament` the puller: `safeTransferFrom` into itself, then
forward. That puts the pot inside a logic contract between two statements and hands a hostile token a
reentrancy hook into `postTask`, which carries no guard. Trading a custody property and a new
reentrancy surface for an automatic approval is the wrong direction, so the schema asks for no
approval and says where the allowance belongs.

If a future `ApproveAction` gains a spender, this becomes a one-line declaration and we will make it.

**The test asserted the defect.** `test_PostTaskDeclaresItsApproval` checked that the approval
exists, that its `tokenType` is `"taxToken"` and its `amountFieldName` is `"pot"`. All three were
right. The declaration was still wrong, because the spender is not a field — so a test written
entirely in terms of fields could not see it. It asserts the property now: no approval is declared
where this contract is not the puller, the description names `vault()`, and the escrow path is
demonstrated in both directions.

**And the general rule is a gate.** This is the second schema/code drift here — the first was
`postTask`'s parameter types, which is why `tools/check-schema.mjs` exists at all, and it compared
names and then types while never asking who receives the money. It now requires that any method
declaring an `ApproveAction` contains `safeTransferFrom(msg.sender, address(this), ...)` in its own
body. Run against the code as you received it, it names `Tournament.postTask` and nothing else: the
vault's own approval on `sponsor` is correct, because `sponsor` does pull into itself, and it is not
flagged.

---

## Status

- 262 tests pass.
- **BSC mainnet redeployed for this submission and carries exactly this source.** Verified by call:
  `tournament.vault()` returns `0x76033A5F2020FB177DeC06481f032800dA37ae2A`, which is the address a poster must approve, and
  `tournament.generator()` and the generator's `tournament()` point at each other.
- **BSC testnet is behind** — that deploy failed for gas and the public faucet is out of funds.
- **No token is launched on mainnet.** `SKIP_TOKEN=true`; `taxToken` is the zero address in
  `deployments/56-latest.json`. A rehearsal token from an earlier round exists on testnet at
  `0x769EfAbeFc18317A846A1E2BdeB831Ba659f7777`, which `test/DepositParity.t.sol` forks chain 97 to
  assert against on every run.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | `0x6b220DACd22467e837249344399A5d52951Ae264` | `0xF5b3243259daA0E9b0CE8f51F6340a89e50B404F` |
| `Tournament` | `0x2d14990a90640435CdbE13BA80e9c57e81d9c5dd` | `0x5196Bbe37D76df30F4Eeb412846946f78E85eb25` |
| `AssayVault` (approve this) | — | `0x76033A5F2020FB177DeC06481f032800dA37ae2A` |
| `TaskGenerator` | — | `0xEEB91744BCA82DCA2fc09513e5a76bdCaE4589B9` |
| Tax token | rehearsal token, see above | not launched |
