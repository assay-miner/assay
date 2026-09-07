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

# The deployment tables in SUBMISSION.md are derived from the manifests. A redeploy used to leave
# them naming the previous contracts, which asks an auditor to look at addresses that do not hold
# the code under review. Refuse to package a stale document rather than ship one.
# The self-describing schema is what a generic UI builds its forms from, and a field that
# disagrees with the ABI produces a form that collects the wrong type. Nothing in the contract
# tests reads the schema, so this is the only place that comparison happens.
node tools/check-schema.mjs || {
  echo "refusing to package: a vaultUISchema field disagrees with the ABI" >&2
  exit 1
}

# The response's shape, when a report is sitting next to it to compare against. Three rounds were
# rejected on format, each time because the shape was inferred rather than copied — the last one
# truncated a finding title at its first comma and the validator reported "Confirmed: 0".
# AUDIT_REPORT is optional: without it the check still catches structure, and says out loud that
# titles were NOT compared so a green run cannot be mistaken for a checked one.
if [ -s AUDIT_RESPONSE_SHORT.md ]; then
  node tools/check-response-format.mjs AUDIT_RESPONSE_SHORT.md "${AUDIT_REPORT:-}" || {
    echo "refusing to package: the response is a shape the validator rejects" >&2
    exit 1
  }
fi

node tools/sync-submission.mjs --check || {
  echo "refusing to package: SUBMISSION.md does not match deployments/*-latest.json" >&2
  exit 1
}

# Our own contracts, plus Flap's base contracts exactly as they were imported.
cp -R src/flap src/interfaces src/mocks "$OUT/src/"
# Every contract, not a list of them. Naming the files meant TaskGen.sol and TaskGenerator.sol
# were added to src/ and never reached the archive, which then did not compile — the same drift
# that had SUBMISSION.md naming contracts from two deployments earlier.
cp src/*.sol "$OUT/src/"

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

# MachineOnly.t.sol reads the shipped task spec off disk rather than restating it, which is the
# point of that suite — so the spec travels with it. Found the same way as script/: by extracting
# the archive into an empty directory and running it, which is the only place a missing file shows.
mkdir -p "$OUT/tasks"
cp tasks/*.json "$OUT/tasks/"

# remappings live inside foundry.toml, not a separate file
# AUDIT_RESPONSE.md is deliberately NOT shipped. It answers round 1's seven findings and nothing
# keeps it current: sync-submission.mjs rewrites SUBMISSION.md only, so every redeploy re-sent a
# document whose address table had stopped moving, alongside a present-tense claim that the
# `pooledInto` flag IS the one-shot rule — the flag this submission's headline argument is about
# having deleted. Two response documents in one archive contradicting each other is worse than one.
cp SELF_CHECK.md SUBMISSION.md AUDIT_RESPONSE_SHORT.md foundry.toml "$OUT/"
# The manifests go in WITHOUT their salt. `predictedToken` is a public consequence of the salt and
# is safe to publish; the salt itself is the thing that lets somebody else deploy at that address
# first. That is not hypothetical here — the launch address this project recorded until today had
# been taken sixteen weeks earlier by an unrelated clone, and while that particular collision came
# from mining at a fixed low offset rather than from anyone reading this archive, an archive that
# carries the salt hands a stranger the one input needed to repeat it deliberately. Deploy's new
# occupancy gate refuses a taken address at deploy time; it cannot help once the address is ours and
# the launch is still ahead of us. So the salt does not leave the building.
strip_salt() {
  node -e '
    const fs = require("fs");
    const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    delete m.salt;
    fs.writeFileSync(process.argv[2], JSON.stringify(m, Object.keys(m).sort(), 2) + "\n");
  ' "$1" "$2"
}
strip_salt "$MANIFEST" "$OUT/deployments/$(basename "$MANIFEST")"
[ -s deployments/97-latest.json ] && strip_salt deployments/97-latest.json "$OUT/deployments/97-latest.json"

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
# Read from foundry.toml rather than restated. This line said "200 runs" for the several rounds
# after optimizer_runs became 1, and a reviewer recompiling at 200 gets different bytecode — the
# sentence directly under it promises the opposite.
OPT_RUNS=$(grep -E '^optimizer_runs' foundry.toml | head -1 | tr -dc '0-9')
[ -n "$OPT_RUNS" ] || { echo "cannot read optimizer_runs from foundry.toml"; exit 1; }
[ "$OPT_RUNS" = "1" ] && OPT_PLURAL="run" || OPT_PLURAL="runs"

cat > "$OUT/README.md" <<EOF
# ASSAY vault — audit package

Chain ${CHAIN} (BNB Smart Chain). Prepared $(date -u +%Y-%m-%d).

## What is being audited

\`AssayFlapFactory\` and the \`AssayFlapVault\` it creates. The vault turns a Flap taxed-V3
token's trading tax into BTCB prize money for a gas-optimisation tournament: tax arrives as
native BNB through \`receive()\`, anyone may schedule its conversion to BTCB and book it behind a task,
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

\`${SOLC}\`, optimizer on at ${OPT_RUNS} ${OPT_PLURAL}, \`via_ir\` on, \`evm_version = cancun\` — pinned in
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
| \`src/\` + \`foundry.toml\` | The repository layout. \`src/\` and \`foundry.toml\` are at the archive root, not inside a wrapper folder, so a tool that does not recurse still finds the contracts. |
| \`flat/*.flat.sol\` | One self-contained file per audited contract, for portals that accept only that. Compile-checked in a clean project: identical runtime length to the repository build, differing only in the trailing CBOR metadata, which encodes source paths and therefore always changes when files are flattened. |
| \`standard-json/*.json\` | The exact solc input. This is the only form that reproduces the deployed bytecode byte for byte. |

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

\`triggerConversion\` and its callback. The conversion used to be priced and broadcast by the same
party, which is exactly the ordering an insider can arrange around; it now goes through Flap's
Trigger Service, so the transaction that touches the pool is submitted by a backend the curator
does not control. \`endow\` remains as a Guardian-only escape hatch for the case where the
scheduler is unavailable — leaving it open to the curator would have fixed nothing.

M-02 in \`SELF_CHECK.md\` sets out what that closes and the one thing it does not: the curator can
still move the pool before scheduling, lowering the spot the floor is measured against. They
cannot act on it, because they do not submit the execution and cannot predict its timing. Whether
that residue is worth a TWAP reference is the question worth your opinion.
EOF

# `zip` UPDATES an existing archive rather than replacing it, so every file ever dropped from this
# package stayed in the shipped zip for ever. Four had accumulated: a superseded round-1 response
# whose address table was two deployments stale, a src/ contract that is no longer part of the
# project, a removed script and a removed task spec — 92 entries against a staging directory of 88.
# Deleting a file from the package looked like it worked and never did.
rm -f dist/assay-vault-audit.zip
( cd "$OUT" && zip -qr ../assay-vault-audit.zip . )
# The zip must contain exactly the staging directory: no ghosts, nothing missing.
diff <(unzip -Z1 dist/assay-vault-audit.zip | grep -v '/$' | sort) \
     <(cd "$OUT" && find . -type f | sed 's|^\./||' | sort) >/dev/null \
  || { echo "zip contents differ from the staging directory"; exit 1; }
echo "  $(ls -lh dist/assay-vault-audit.zip | awk '{print $5}')  dist/assay-vault-audit.zip"
echo "  $(find "$OUT" -type f | wc -l | tr -d ' ') files"
# The README is written through an unquoted heredoc, so it interpolates — which means a backtick
# that is not escaped runs as a command and its output replaces the text. That has now silently
# deleted a filename from the shipped README twice: once foundry.toml, once the two rows naming
# flat/ and standard-json/. A reader just sees an empty table cell. Check the product, not the
# template: an empty cell is the signature and nothing legitimate produces one.
if grep -nE '^\|[[:space:]]*\|[[:space:]]*[^|[:space:]]' "$OUT/README.md" >/dev/null; then
  echo "refusing to package: README.md has an empty table cell — an unescaped backtick in the" >&2
  echo "heredoc ran as a command and ate the text. Escape it as \\\` and re-run." >&2
  grep -nE '^\|[[:space:]]*\|[[:space:]]*[^|[:space:]]' "$OUT/README.md" >&2
  exit 1
fi

echo
echo "verifying the archive the way a reviewer will…"
./tools/verify-audit-package.sh dist/assay-vault-audit.zip
