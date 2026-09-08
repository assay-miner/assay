#!/usr/bin/env bash
# Every gate this repository has, in one command.
#
# It exists because of a gate that was red and unread. `miner/src/abi.ts` carries a generated ABI
# slice and `miner` ships its own drift check, `npm run check-abi`. When that vault function was
# deleted, app/src/abi.ts and flap-ui/VaultABI.ts were regenerated and miner's was not — so that
# check was failing, and stayed failing, because nothing in any workflow ran it. The miner client
# was holding an ABI with a function the chain no longer has.
#
# A gate nobody runs is not a gate. So they all run here, and the packaging steps call this rather
# than each remembering its own subset.
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

bad=0
FAILED_STEPS=()
step() {
  local what="$1"; shift
  printf '\n→ %s\n' "$what"
  if "$@"; then return 0; fi
  echo "   FAILED"
  # Naming them again at the end matters: the packaging script pipes this into a log and prints its
  # tail, so a failure fifty lines up scrolls off and the caller sees only "something is out of
  # step" with no idea which gate. A summary that omits what failed is a gate that reports nothing.
  FAILED_STEPS+=("$what")
  bad=1
}

forge build >/dev/null 2>&1 || { echo "forge build failed"; exit 1; }

step "schema fields agree with the ABI"        node tools/check-schema.mjs
step "flap-ui ABI slice matches the contracts" node tools/sync-flap-ui-abi.mjs --check
step "flap-ui bindings match the deployments"  node tools/sync-ui-addresses.mjs --check
step "SUBMISSION.md matches the manifests"     node tools/sync-submission.mjs --check
step "miner's ABI slice matches"               bash -c 'cd miner && npm run --silent check-abi'
step "no bare implementations, layout pinned"  bash tools/check-upgradeable.sh
step "no live references to removed symbols"   node tools/check-symbols.mjs

if [ "$bad" != 0 ]; then
  printf '\nout of step with the contracts:\n' >&2
  for f in "${FAILED_STEPS[@]}"; do printf '  ✗ %s\n' "$f" >&2; done
  exit 1
fi
printf '\nevery gate green\n'
