# ASSAY

A gas-optimisation tournament settled on chain, paid for by a token's trading tax.

A task is a set of calldata inputs, the keccak256 of each expected output, and a gas baseline.
Miners submit raw EVM runtime bytecode. The chain deploys it behind a constructor-free prologue,
runs every test vector under `STATICCALL`, and reads the meter. Score is `baselineGas × 1e18 /
gasUsed`, capped at 32×. Nobody grades anything; the meter does.

The same submission is paid twice, by two contracts, in two assets: the ASSAY pot the task was
posted with, and a share of BTCB bought with the token's trading tax while that task was open.

## Layout

| Path | What |
|---|---|
| `src/Crucible.sol` | Deploys a submission and meters it |
| `src/Tournament.sol` | Commit–reveal, scoring, settlement |
| `src/AgentRoster.sol` | ERC-8004 identity + stake |
| `src/AssayVault.sol` | Custody. No owner, no upgrade, no sweep of accounted funds |
| `src/AssayFlapVault.sol` | The Flap-facing vault: tax in as BNB, BTCB out to scoring miners |
| `src/AssayFlapFactory.sol` | Creates one of those per launched token |
| `miner/` | The miner client — `status \| enrol \| mine \| reveal \| claim \| collect` |
| `app/` | The protocol's own site |
| `flap-ui/` | Custom vault component for flap.sh |

## Operating it

Three commands. Every address is chained through `deployments/<chainid>-latest.json`; none is
ever pasted.

```bash
CHAIN_ID=97 PRIVATE_KEY=0x… ./launch   # stack, taxed token, vault
CHAIN_ID=97 PRIVATE_KEY=0x… ./post     # post a task, convert the tax behind it
CHAIN_ID=97 PRIVATE_KEY=0x… ./exit     # reclaim your own unwon pots, immediately
```

## Testing

```bash
forge test                 # the whole suite; six of its files fork real BSC state
./tools/rehearse.sh        # the whole protocol end to end against a fork, in ~33s
```

The rehearsal needs a fork running:

```bash
anvil --fork-url https://bsc-testnet-rpc.publicnode.com --port 8546 --chain-id 97 --silent
```

It exists because every path it walks was written and none had been executed. The first run found
three defects, and it is proven red by breaking what it guards.

## Flap integration

- [`SELF_CHECK.md`](SELF_CHECK.md) — the vault against Flap's published rule set. 0 Critical,
  0 High, 2 Medium, and both Mediums are disclosures rather than defects.
- [`SUBMISSION.md`](SUBMISSION.md) — the seven integration steps, and what each one is waiting on.
- [`flap-ui/README.md`](flap-ui/README.md) — the custom component, and what could not cross the
  runtime's boundary.

## What the operator cannot do

`./exit` is not a withdrawal. `payOut` is the only function that moves ASSAY out of custody and
it has exactly three call sites, each with a hardcoded destination: a miner taking their own
stake back to themselves, a scored miner claiming their own share to themselves, and `reclaim`
returning `pot - paidOut` — the part of a task's prize nobody won — to the address that escrowed
it. None of them accepts a caller-supplied recipient. `reclaim` also waits: past the reveal, and
if anyone scored at all, past the full claim window as well, so miners are paid before anything
goes back.

The BTCB has no operator path at all. It leaves `AssayFlapVault` in two ways: `collect`, which
pays `msg.sender` and only if the tournament recorded a score for them, and the Rule 009
emergency functions, which are `onlyGuardian` — and the Guardian is Flap's address, not ours.

## Notes on what this is not

The tournament's tasks are posted by a curator. That is the centralised part of this version and
it is not hidden: the verification core trusts nobody, but *what gets mined* currently does. The
next step is the ERC-8183 escrow path, where anyone posts a task with a bounty and this contract
acts as the delivery evaluator — the verification core does not change to get there.

Flap's Guardian can withdraw from the Flap-facing vault. That is required of every non-upgradeable
vault by their Rule 009, and it reaches BTCB behind open bounties. It adds no trust assumption
their portal does not already carry, and `solvent()` exists so that any gap between the ledger and
the balance is visible from outside.
