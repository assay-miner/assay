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
step() {
  printf '\n→ %s\n' "$1"; shift
  if "$@"; then return 0; fi
  echo "   FAILED"; bad=1
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
  printf '\nsomething is out of step with the contracts\n' >&2
  exit 1
fi
printf '\nevery gate green\n'
