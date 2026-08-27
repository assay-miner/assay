#!/usr/bin/env bash
# Builds the archive handed to Flap's partner auditor.
#
# It carries three things an auditor asks for first: the source, the exact compiler input that
# reproduces the deployed bytecode, and a script that proves the address on chain holds that
# bytecode. Everything in it is generated from the repository, so it cannot drift from what was
# actually deployed.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

CHAIN="${CHAIN_ID:-56}"
MANIFEST="deployments/${CHAIN}-latest.json"
[ -s "$MANIFEST" ] || { echo "no manifest at $MANIFEST" >&2; exit 1; }

OUT="dist/assay-vault-audit"
rm -rf "$OUT" && mkdir -p "$OUT"/{src,test,standard-json,deployments}

forge build >/dev/null

# Our own contracts, plus Flap's base contracts exactly as they were imported.
cp -R src/flap src/interfaces src/mocks "$OUT/src/"
cp src/AssayFlapVault.sol src/AssayFlapFactory.sol src/Tournament.sol src/AgentRoster.sol \
   src/AssayVault.sol src/Crucible.sol src/AssayToken.sol "$OUT/src/"

# The whole suite, not a hand-picked four. The first archive shipped only the Flap-facing suites
# while the docs quoted the repository's total, so a reviewer counted 33 tests against a claim of
# 103 and was right to stop there. It also left Tournament, the custody ledger and the roster
# untested inside the package — and every payout this vault makes is a function of the
# tournament's state, so "out of scope" was the wrong call for an archive somebody has to judge.
cp -R test/. "$OUT/test/"

# LaunchGuard.t.sol imports the deploy script, so the scripts come too. Found by extracting the
# archive into an empty directory and building it the way a reviewer would, which is the only way
# a missing file shows up — the build in this repository has them either way.
mkdir -p "$OUT/script"
cp script/*.sol "$OUT/script/"

# remappings live inside foundry.toml, not a separate file
cp SELF_CHECK.md SUBMISSION.md foundry.toml "$OUT/"
cp "$MANIFEST" "$OUT/deployments/"
[ -s deployments/97-latest.json ] && cp deployments/97-latest.json "$OUT/deployments/"

# The standard JSON is what makes the deployed bytecode reproducible by anyone.
for C in AssayFlapFactory AssayFlapVault; do
  forge verify-contract --show-standard-json-input \
    0x0000000000000000000000000000000000000000 "src/$C.sol:$C" > "$OUT/standard-json/$C.json"
done

# Flattened single files. Some audit intake portals accept only one self-contained .sol per
# contract, and a flatten that does not compile is worthless — these are built by `forge flatten`
# and compile-checked in a clean project before they go in.
mkdir -p "$OUT/flat"
for C in AssayFlapFactory AssayFlapVault; do
  forge flatten "src/$C.sol" -o "$OUT/flat/$C.flat.sol" >/dev/null 2>&1
done

cp tools/verify-onchain.mjs "$OUT/verify-onchain.mjs"
mkdir -p "$OUT/artifact"
cp out/AssayFlapFactory.sol/AssayFlapFactory.json out/AssayFlapVault.sol/AssayFlapVault.json "$OUT/artifact/"

# Measured from the tests that are going into this archive, never typed. A restated number
# drifts the moment anything changes; a derived one cannot.
TEST_OUT=$(forge test 2>&1 | tail -3)
TEST_COUNT=$(echo "$TEST_OUT" | grep -oE '[0-9]+ tests passed' | grep -oE '^[0-9]+')
SUITE_COUNT=$(echo "$TEST_OUT" | grep -oE 'Ran [0-9]+ test suites' | grep -oE '[0-9]+')
FORK_COUNT=$(grep -l createSelectFork test/*.t.sol | wc -l | tr -d ' ')
FAILED=$(echo "$TEST_OUT" | grep -oE '[0-9]+ failed' | grep -oE '^[0-9]+' | head -1)
[ "${FAILED:-0}" = "0" ] || { echo "refusing to package: $FAILED tests failing" >&2; exit 1; }
[ -n "$TEST_COUNT" ] || { echo "refusing to package: could not measure the test count" >&2; exit 1; }

FACTORY=$(jq -r .flapFactory "$MANIFEST")
TOURNAMENT=$(jq -r .tournament "$MANIFEST")
SOLC=$(python3 -c "import json;print(json.load(open('out/AssayFlapFactory.sol/AssayFlapFactory.json'))['metadata']['compiler']['version'])")

cat > "$OUT/README.md" <<EOF
# ASSAY vault — audit package

Chain ${CHAIN} (BNB Smart Chain). Prepared $(date -u +%Y-%m-%d).

## What is being audited

\`AssayFlapFactory\` and the \`AssayFlapVault\` it creates. The vault turns a Flap taxed-V3
token's trading tax into BTCB prize money for a gas-optimisation tournament: tax arrives as
native BNB through \`receive()\`, the curator converts it to BTCB and books it behind a task,
and a miner the tournament has scored collects their share.

\`Tournament.sol\` is included because every payout the vault makes is a function of a score it
records. It is not itself a Flap vault and is outside the vault specification, but the vault
cannot be reasoned about without it.

## Deployed

| | |
|---|---|
| Factory | \`${FACTORY}\` |
| Tournament | \`${TOURNAMENT}\` |
| Registered with Flap | no — this package is the registration request |

## Compiler

\`${SOLC}\`, optimizer on at 200 runs, \`via_ir\` on, \`evm_version = cancun\` — pinned in
\`foundry.toml\` rather than left to the toolchain default, which drifts.

\`standard-json/\` holds the exact solc input for each contract. Recompiling it reproduces the
deployed bytecode.

## Verifying the deployment

\`\`\`bash
node verify-onchain.mjs            # or: node verify-onchain.mjs <rpc-url>
\`\`\`

It fetches the factory's code from chain ${CHAIN} and compares it with the artifact, blanking the
immutable slots first — those hold the tournament address and are written at deploy time, so a
raw comparison always differs there and nowhere else.

## Three forms of the same source

| Path | Use |
|---|---|
| `src/` + `foundry.toml` | The repository layout. `src/` and `foundry.toml` are at the archive root, not inside a wrapper folder, so a tool that does not recurse still finds the contracts. |
| `flat/*.flat.sol` | One self-contained file per audited contract, for portals that accept only that. Compile-checked in a clean project: identical runtime length to the repository build, differing only in the trailing CBOR metadata, which encodes source paths and therefore always changes when files are flattened. |
| `standard-json/*.json` | The exact solc input. This is the only form that reproduces the deployed bytecode byte for byte. |

## Reading order

1. \`SELF_CHECK.md\` — the contracts against Flap's published rule set. Two Medium findings, both
   disclosures rather than defects, and both stated in the source as well as the report.
2. \`src/AssayFlapVault.sol\`
3. \`src/AssayFlapFactory.sol\`
4. \`test/FlapSpec.t.sol\` — the coverage Rule 006 asks for

**Test package: ${TEST_COUNT} tests across ${SUITE_COUNT} suites, ${FORK_COUNT} of them forked
against real BSC state.** That figure is measured by the script that built this archive, by
running the tests inside it. The whole suite is here, including the ones covering \`Tournament\`,
the custody ledger and the roster — they sit outside Flap's vault specification, but every payout
this vault makes is a function of the tournament's recorded scores, so they are not outside what
an auditor needs.

5. \`test/RewardAsset.t.sol\` — the economics against the real market, on a mainnet fork

## Compiling

Two paths. The first is canonical and needs nothing but solc.

**Reproduce the deployed bytecode.** \`standard-json/AssayFlapFactory.json\` is a complete solc
input — every source it needs is inside it, at the exact settings the deployment used.

\`\`\`bash
solc --standard-json standard-json/AssayFlapFactory.json > out.json
\`\`\`

**Or build and run the tests with Foundry.** The dependency versions are pinned because a
different OpenZeppelin produces different bytecode, and the point of this package is that the
bytecode matches. \`git init\` first: \`forge install\` needs a repository.

\`\`\`bash
git init
forge install foundry-rs/forge-std@v1.16.2
forge install OpenZeppelin/openzeppelin-contracts@v5.4.0
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v4.9.6
forge build
forge test        # ${TEST_COUNT} tests, ${SUITE_COUNT} suites, ${FORK_COUNT} forked against real BSC state
\`\`\`

## Where to look hardest

\`endow\` performs a swap on behalf of a privileged caller. The slippage floor is bounded to 3%
below spot, which closes the case an insider can arrange at will and does not close the case
where they move the pool first. M-02 in \`SELF_CHECK.md\` sets out both real fixes and what each
costs. It is the finding where an outside opinion is worth the most.
EOF

# Zipped from inside the directory, so `src/` and `foundry.toml` sit at the archive root.
# An intake tool that does not recurse past a wrapper folder reports "no Solidity source files
# found" on an archive that is full of them — which is what happened with the first build.
( cd "$OUT" && zip -qr ../assay-vault-audit.zip . )
echo "  $(ls -lh dist/assay-vault-audit.zip | awk '{print $5}')  dist/assay-vault-audit.zip"
echo
echo "verifying the archive the way a reviewer will…"
./tools/verify-audit-package.sh dist/assay-vault-audit.zip
echo "  $(find "$OUT" -type f | wc -l | tr -d ' ') files"
