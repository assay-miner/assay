#!/usr/bin/env bash
# The whole protocol, end to end, against a fork — launch, tax, task, mine, reveal, claim, collect.
#
# This exists because every path it walks was written and none of them had ever run. The first
# time it was executed it found two: the miner could not see the BTCB bounty at all, and the
# rival-bytecode seed scan asked for `fromBlock: 0` on a 127-million-block chain, so it had never
# once worked and said so in a line that read like the node's fault.
#
# Needs a running fork:
#   anvil --fork-url https://bsc-testnet-rpc.publicnode.com --port 8546 --chain-id 97 --silent
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

R="${REHEARSE_RPC:-http://127.0.0.1:8546}"
REG=0x8004A818BFB912233c491871b3d84c89A494BD9e
BTCB=0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8
AGENT="${REHEARSE_AGENT:-42}"
TAX="${REHEARSE_TAX:-6ether}"

step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$1" >&2; exit 1; }

cast block-number --rpc-url "$R" >/dev/null 2>&1 || fail "no fork at $R — start anvil first"

# A rehearsal writes a manifest and a frontend env that are indistinguishable from a real
# deployment's, and fork addresses left in either place are a live trap. Whatever was here
# before comes back, and the run's own output is filed under a name nobody can mistake.
MANIFEST=deployments/97-latest.json
ENVFILE=app/.env.local
KEEP=$(mktemp -d)
[ -f "$MANIFEST" ] && cp "$MANIFEST" "$KEEP/manifest"
[ -f "$ENVFILE" ] && cp "$ENVFILE" "$KEEP/env"
restore() {
  if [ -f "$MANIFEST" ]; then cp "$MANIFEST" deployments/97-fork-rehearsal.json; fi
  if [ -f "$KEEP/manifest" ]; then cp "$KEEP/manifest" "$MANIFEST"; else rm -f "$MANIFEST"; fi
  if [ -f "$KEEP/env" ]; then cp "$KEEP/env" "$ENVFILE"; else rm -f "$ENVFILE"; fi
  rm -rf "$KEEP"
  rm -f miner/.miner-state.json
}
trap restore EXIT

step "a fresh deployer"
# Not an anvil default account: those carry 7702 delegations on a BSC fork, and code at the
# deployer changes what a launch does.
PK=0x$(openssl rand -hex 32)
ME=$(cast wallet address --private-key "$PK")
cast rpc anvil_setBalance "$ME" 0x21e19e0c9bab2400000 --rpc-url "$R" >/dev/null
[ "$(cast code "$ME" --rpc-url "$R")" = "0x" ] || fail "deployer has code — pick another key"
echo "  $ME"

step "take a real ERC-8004 identity"
OWNER=$(cast call "$REG" 'ownerOf(uint256)(address)' "$AGENT" --rpc-url "$R")
cast rpc anvil_impersonateAccount "$OWNER" --rpc-url "$R" >/dev/null
cast rpc anvil_setBalance "$OWNER" 0xde0b6b3a7640000 --rpc-url "$R" >/dev/null
cast send "$REG" 'transferFrom(address,address,uint256)' "$OWNER" "$ME" "$AGENT" \
  --from "$OWNER" --unlocked --rpc-url "$R" >/dev/null
cast rpc anvil_stopImpersonatingAccount "$OWNER" --rpc-url "$R" >/dev/null
[ "$(cast call "$REG" 'isAuthorizedOrOwner(address,uint256)(bool)' "$ME" "$AGENT" --rpc-url "$R")" = "true" ] \
  || fail "identity transfer did not take"
echo "  agent #$AGENT"

step "launch"
export CHAIN_ID=97 RPC_URL="$R" PRIVATE_KEY="$PK"
./launch >/dev/null
VAULT=$(jq -r .flapVault "$MANIFEST")
TAXTOKEN=$(jq -r .taxToken "$MANIFEST")
[ -n "$(jq -r '.deployBlock // ""' "$MANIFEST")" ] || fail "manifest has no deployBlock"
case "$TAXTOKEN" in *7777) ;; *) fail "tax token does not end in 7777: $TAXTOKEN" ;; esac
[ "$(cast call "$VAULT" 'solvent()(bool)' --rpc-url "$R")" = "true" ] || fail "vault starts insolvent"
grep -q '^VITE_FLAP_VAULT=' app/.env.local || fail "vault address was not chained into the frontend"
echo "  token $TAXTOKEN   vault $VAULT"

step "tax arrives, task is posted and endowed"
cast send "$VAULT" --value "$TAX" --private-key "$PK" --rpc-url "$R" >/dev/null
[ "$(cast call "$VAULT" 'unassigned()(uint256)' --rpc-url "$R" | awk '{print $1}')" != "0" ] || fail "tax did not arrive"
./post >/dev/null
BOUNTY=$(cast call "$VAULT" 'bounty(uint256)(uint256)' 1 --rpc-url "$R" | awk '{print $1}')
[ "$BOUNTY" != "0" ] || fail "post did not endow the task"
[ "$(cast call "$VAULT" 'unassigned()(uint256)' --rpc-url "$R" | awk '{print $1}')" = "0" ] \
  || fail "tax was left unconverted"
echo "  bounty $BOUNTY BTCB behind task 1"

step "mine"
cd miner
export AGENT_ID="$AGENT"
npm run --silent mine -- enrol >/dev/null
npm run --silent mine -- mine 1 2>&1 | grep -Ev '^\s*$' | sed 's/^/  /'
cd ..

step "reveal and settle"
cast rpc evm_increaseTime 3700 --rpc-url "$R" >/dev/null; cast rpc evm_mine --rpc-url "$R" >/dev/null
(cd miner && npm run --silent mine -- reveal 1 >/dev/null)
cast rpc evm_increaseTime 3700 --rpc-url "$R" >/dev/null; cast rpc evm_mine --rpc-url "$R" >/dev/null

step "both paydays"
BEFORE=$(cast call "$BTCB" 'balanceOf(address)(uint256)' "$ME" --rpc-url "$R" | awk '{print $1}')
(cd miner && npm run --silent mine -- status 2>&1 | sed 's/^/  /')
(cd miner && npm run --silent mine -- claim 1 2>&1 | sed 's/^/  /')
(cd miner && npm run --silent mine -- collect 1 2>&1 | sed 's/^/  /')
AFTER=$(cast call "$BTCB" 'balanceOf(address)(uint256)' "$ME" --rpc-url "$R" | awk '{print $1}')

# The balance delta, not the receipt: a successful receipt that moved nothing is not a payout.
[ "$AFTER" != "$BEFORE" ] || fail "collect moved no BTCB"
[ "$AFTER" = "$BOUNTY" ] || fail "collected $AFTER but the bounty was $BOUNTY"
[ "$(cast call "$VAULT" 'solvent()(bool)' --rpc-url "$R")" = "true" ] || fail "vault left insolvent"

step "the rival-seed scan really reads logs"
# The point of the fix: with a reveal on chain, the scan must find it. A run that reports no
# rivals here is indistinguishable from the version that could never look, which is exactly the
# state this was in. The commit afterwards fails because the window has closed; only the seed
# line matters.
SEEDS=$(cd miner && npm run --silent mine -- mine 1 2>&1 || true)
echo "$SEEDS" | grep -q 'rival submission(s) already revealed' \
  || fail "the reveal on chain was not picked up as a seed"
echo "$SEEDS" | grep -q 'reveal history incomplete' \
  && fail "the node refused a window the scan should have handled"
echo "  $(echo "$SEEDS" | grep 'rival submission')"

step "second collect must refuse"
(cd miner && npm run --silent mine -- collect 1 2>&1 | grep -q 'already collected') \
  || fail "a second collect did not report as already collected"

printf '\n\033[32mrehearsal clean — %s BTCB and the ASSAY pot both reached the miner\033[0m\n' "$AFTER"
echo "fork addresses filed under deployments/97-fork-rehearsal.json; nothing real was touched"
