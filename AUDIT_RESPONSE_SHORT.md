# Flap Vault Interaction Risk Report — response

Generated: 2026-09-07 07:18:22 UTC · Project: ASSAY (`AssayFlapVault`)

Accepted. Every link holds, and the report understates it by one consequence.

---

## Risk Findings
### Finding 1: Agent id is silently truncated to uint64 in commit, breaking reveal for large ERC-8004 identities
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** AgentRoster.enroll accepts an arbitrary uint256 agentId with no upper bound, and Tournament stores it in the reverse index and enrolment as a full uint256. However, Tournament.Submission.agentId is a uint64 and Tournament.commit narrows it with `s.agentId = uint64(agentId)`. Tournament.reveal then verifies the commitment against `keccak256(abi.encode(runtime, salt, uint256(s.agentId)))` — i.e. the truncated value. The commit NatSpec documents the commitment as `keccak256(abi.encode(runtime, salt, agentId))` using the full agent id. For any enrolled agentId greater than 2^64-1, a miner who forms their commitment per the documented formula (full agent id) will always fail the reveal check with 'Commitment mismatch', so they cannot reveal, cannot score, and their stake stays locked until revealEnd for nothing.
- **Vulnerable Code:**
  - `src/Tournament.sol:commit (s.agentId = uint64(agentId))`
  - `src/Tournament.sol:reveal (keccak256(abi.encode(runtime, salt, uint256(s.agentId))))`
  - `src/AgentRoster.sol:enroll (no agentId <= type(uint64).max bound)`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Bounded at enrolment — `require(agentId <= type(uint64).max)` in `AgentRoster.enroll` — rather than widening the submission field, because that is where the refusal costs the caller nothing. Confirmed by removing the bound and watching exactly the one test fail.

**Verified link by link.** `Submission.agentId` is a `uint64` at `src/Tournament.sol:128`; `commit`
narrows to it at `:412`; `reveal` recomputes the commitment from that narrowed value at `:432`; the
NatSpec at `:398` documents the full id. `AgentRoster.enroll` bounded `agentId` against zero and
nothing else.

**Understated by one consequence.** The same narrowed field is read by the `Revealed` event at
`:455` and by the leaderboard card at `:580`. So a large-id miner who somehow got past the reveal
would be labelled with the wrong agent everywhere the protocol displays one — the truncation is not
only a reveal failure, it is a wrong identity in the record.

**Bounded rather than widened, and the reason is where the cost falls.** Refusing at enrolment costs
the caller nothing: no stake has moved. Failing at reveal costs them a locked stake — `commit` hands
`revealEnd` to `roster.lockUntil`, which only ever raises the lock — and a wasted epoch of search.
Widening `Submission.agentId` to `uint256` would spend a storage slot on every commit, permanently,
for a case that requires about 1.8×10^19 identities to exist.

**That number is measured rather than assumed.** The ERC-8004 registry this deployment points at
mints sequential ERC-721 ids: `ownerOf(1)`, `ownerOf(2)` and `ownerOf(100)` all resolve to real
owners on chain today. No real caller reaches this bound. The bound is there because the registry is
a contract we do not control, and for a failure whose cost is a locked stake, "impossible" is worth
more than "improbable".

**Tested from both sides of the boundary.**
`test_AnAgentIdTooLargeForASubmissionIsRefusedAtEnrolment` mints `type(uint64).max + 1`, asserts the
refusal, and asserts no stake moved. `test_TheLargestIdASubmissionCanHoldStillEnrols` mints exactly
`type(uint64).max` and enrols with it, so the bound is the value it claims to be rather than one off
it. Removing the bound makes the first fail with "next call did not revert as expected" and leaves
the other eleven in that file green.

---

## Status

- 269 tests pass.
- **BSC mainnet redeployed and carries exactly this source.** Every manifest address has code,
  checked by the packaging step rather than assumed. The deployer, the curator and the salvage
  address are one key, asserted on chain by `tournament.curator()`.
- **BSC testnet: nothing deployed.** The manifest for chain 97 records a deploy that failed for gas;
  `eth_getCode` returns empty for every address in it, and `tools/sync-submission.mjs` now asks the
  chain and labels that table accordingly rather than calling it a proof deployment.
- **No token is launched.** `SKIP_TOKEN=true`; `taxToken` is the zero address in
  `deployments/56-latest.json`. A rehearsal token from an earlier round exists on testnet at
  `0x769EfAbeFc18317A846A1E2BdeB831Ba659f7777`, which `test/DepositParity.t.sol` forks chain 97 to
  assert against on every run.

| | BSC testnet (97) | BSC mainnet (56) |
|---|---|---|
| `AssayFlapFactory` | not deployed | `0x22db6EB62341Ed52E94A6626B44fc4377F762C91` |
| `Tournament` | not deployed | `0x17b827D2a8676A37341BcF42CEF1a8eb2ef8De0F` |
| `AssayVault` (approve this) | not deployed | `0x12dFE705723eef7b5e685E5864938097e1C0F8Db` |
| `AgentRoster` | not deployed | `0x84069e8Ec3f9FeA05CB99D3fF1Ce61be0FbbE5F1` |
| `TaskGenerator` | not deployed | `0xD54496d5DF12527B7b76f9Ce0e1ae2F4D8C90A43` |
| Curator (`withdrawUnconverted` pays) | — | `0x9E591947199091D4ff23DCF9Ab1C88576bd550e8` |
| Tax token | rehearsal token, see above | not launched |
