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

cp test/FlapSpec.t.sol test/RewardAsset.t.sol test/FlapGate.t.sol test/FlapRender.t.sol \
   test/Base.t.sol test/Bytecode.sol test/CrucibleHarness.sol "$OUT/test/"

# remappings live inside foundry.toml, not a separate file
cp SELF_CHECK.md SUBMISSION.md foundry.toml "$OUT/"
cp "$MANIFEST" "$OUT/deployments/"
[ -s deployments/97-latest.json ] && cp deployments/97-latest.json "$OUT/deployments/"

# The standard JSON is what makes the deployed bytecode reproducible by anyone.
for C in AssayFlapFactory AssayFlapVault; do
  forge verify-contract --show-standard-json-input \
    0x0000000000000000000000000000000000000000 "src/$C.sol:$C" > "$OUT/standard-json/$C.json"
done

cp tools/verify-onchain.mjs "$OUT/verify-onchain.mjs"
mkdir -p "$OUT/artifact"
cp out/AssayFlapFactory.sol/AssayFlapFactory.json out/AssayFlapVault.sol/AssayFlapVault.json "$OUT/artifact/"

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

## Reading order

1. \`SELF_CHECK.md\` — the contracts against Flap's published rule set. Two Medium findings, both
   disclosures rather than defects, and both stated in the source as well as the report.
2. \`src/AssayFlapVault.sol\`
3. \`src/AssayFlapFactory.sol\`
4. \`test/FlapSpec.t.sol\` — the coverage Rule 006 asks for
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
forge test        # forked; needs an RPC that serves state at a recent block
\`\`\`

## Where to look hardest

\`endow\` performs a swap on behalf of a privileged caller. The slippage floor is bounded to 3%
below spot, which closes the case an insider can arrange at will and does not close the case
where they move the pool first. M-02 in \`SELF_CHECK.md\` sets out both real fixes and what each
costs. It is the finding where an outside opinion is worth the most.
EOF

( cd dist && zip -qr assay-vault-audit.zip assay-vault-audit )
echo "  $(ls -lh dist/assay-vault-audit.zip | awk '{print $5}')  dist/assay-vault-audit.zip"
echo "  $(find "$OUT" -type f | wc -l | tr -d ' ') files"
