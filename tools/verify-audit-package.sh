#!/usr/bin/env bash
# Builds and tests the audit archive the way a reviewer will: extracted into an empty directory,
# with nothing from this repository on the path.
#
# This exists because the packaging script measures the test count by running the tests *here*,
# and "here" is not "there". The first archive that shipped the whole suite did not compile at
# all — one test imports the deploy script, and `script/` was not being packaged. Nothing in this
# repository could have noticed: the file is present locally either way.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

# Resolve the argument against the caller's directory BEFORE moving. Resolving it after the cd
# made every relative path point into the repository instead, so passing a deliberately broken
# archive silently checked the good one and the gate reported nothing at all.
ZIP="${1:-}"
if [ -n "$ZIP" ]; then
  case "$ZIP" in /*) ;; *) ZIP="$PWD/$ZIP" ;; esac
fi
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
ZIP="${ZIP:-$PWD/dist/assay-vault-audit.zip}"
[ -s "$ZIP" ] || { echo "no archive at $ZIP" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
unzip -q "$ZIP" -d "$WORK"
cd "$WORK"

ok()  { printf '  \033[32mok  \033[0m %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
FAILED=0

[ -d src ] && [ -f foundry.toml ] && ok "src/ and foundry.toml at the archive root" \
  || bad "an intake tool scanning the root will not find the contracts"
[ "$(find src -name '*.sol' | wc -l | tr -d ' ')" -gt 0 ] && ok "$(find src -name '*.sol' | wc -l | tr -d ' ') Solidity files under src/" || bad "no Solidity under src/"
[ "$(ls flat/*.sol 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] && ok "flattened single files present" || bad "no flattened sources"

git init -q .
# `|| true` on each: forge install returns non-zero on a warning, and `set -e` turned that into a
# silent early exit that made this gate report three passing checks and stop.
forge install foundry-rs/forge-std@v1.16.2 >/dev/null 2>&1 || true
forge install OpenZeppelin/openzeppelin-contracts@v5.4.0 >/dev/null 2>&1 || true
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v4.9.6 >/dev/null 2>&1 || true
[ -d lib/forge-std ] || { echo "  dependencies did not install; cannot verify" >&2; exit 1; }

forge build >/dev/null 2>&1 && ok "compiles from a clean extraction" || { bad "does not compile"; forge build 2>&1 | grep -E '^Error|not found' | head -3 | sed 's/^/       /'; }

# `|| true`: a failing suite must be reported, not exit the gate. Without it `set -e` turned a
# red test into the script simply stopping after the compile line, which reads as "still running"
# rather than "your archive is broken" — the same silent-exit shape as the forge install above.
# The WHOLE output, not `| tail -3`.
#
# That pipe measured nothing here: the summary happens to be the last line in the repository, so the
# gate looked correct, while in a clean extraction forge printed lint warnings after it and the grep
# below found no number at all. The verifier then reported "tests did not pass cleanly" and
# "measured  / " for a suite that was passing. A gate whose reading depends on how many lines a tool
# decides to print after its answer is a gate that will one day be wrong in the other direction.
#
# The pipe also discarded forge's exit code, which is the same defect that let a frontend that could
# not compile sit behind a green `npm run verify` earlier in this project.
OUT=$(forge test 2>&1); TEST_STATUS=$?
RAN=$(echo "$OUT" | grep -oE '[0-9]+ tests passed' | grep -oE '^[0-9]+' || true)
SUITES=$(echo "$OUT" | grep -oE 'Ran [0-9]+ test suites' | grep -oE '[0-9]+' || true)
FAIL=$(echo "$OUT" | grep -oE '[0-9]+ failed' | grep -oE '^[0-9]+' | head -1 || true)
if [ "$TEST_STATUS" != "0" ]; then
  bad "forge test exited $TEST_STATUS"
  printf '%s\n' "$OUT" | grep -E '^\[FAIL' | sort -u | head -10 | sed 's/^/    /'
elif [ -z "$RAN" ]; then
  bad "forge test passed but printed no summary this gate could read"
  printf '%s\n' "$OUT" | tail -5 | sed 's/^/    /'
else
  ok "$RAN tests pass across $SUITES suites"
fi

# The claim in the README has to survive being measured. This is the check that was missing when a
# reviewer counted 33 tests against a documented 103.
CLAIM_T=$(grep -oE 'Test package: [0-9]+ tests' README.md | grep -oE '[0-9]+' || true)
CLAIM_S=$(grep -oE 'across [0-9]+ suites' README.md | grep -oE '[0-9]+' || true)
if [ "$CLAIM_T" = "$RAN" ] && [ "$CLAIM_S" = "$SUITES" ]; then
  ok "the archive's stated counts match what it actually runs ($RAN/$SUITES)"
else
  bad "stated $CLAIM_T tests / $CLAIM_S suites, measured $RAN / $SUITES"
fi

node verify-onchain.mjs >/dev/null 2>&1 && ok "deployed bytecode matches the packaged source" || bad "on-chain verification failed"

# Every address in the archive's prose must be current, third-party, or marked historical. A grep
# for the addresses you remember can only find those; this enumerates all of them.
if ADDR_OUT=$(node "$REPO_ROOT/tools/check-package-addresses.mjs" . 2>&1); then
  ok "every address in the prose is current or marked historical"
else
  bad "stale addresses presented as current"
  printf '%s\n' "$ADDR_OUT" | sed 's/^/    /'
fi

[ "$FAILED" = "0" ] && printf '\n\033[32marchive verified — safe to send\033[0m\n' || { printf '\n\033[31marchive is not sendable\033[0m\n'; exit 1; }
