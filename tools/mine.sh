#!/usr/bin/env bash
# Mines one epoch: solve, commit, wait out the commit window, reveal, then collect.
#
# The seed and draw count come from the epoch spec, and the program they derive is checked against
# the hashes already on chain before anything is sent -- so the spec can arrive over any channel.
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

: "${RPC_URL:?}"; : "${TOURNAMENT:?}"; : "${MINER_KEY:?}"; : "${TASK_ID:?}"; : "${AGENT_ID:?}"
SPEC="${SPEC:-tasks/epoch.json}"
export MINER_NONCE="${MINER_NONCE:-$(openssl rand -hex 16)}"
export SEED=$(python3 -c "import json;print(int(json.load(open('$SPEC'))['seed'],16))")
export DRAWS=$(python3 -c "import json;print(json.load(open('$SPEC'))['draws'])")

# Windows are read from the chain, not from the spec: the spec says how long they are, the chain
# says when they started, and only the second one can be raced.
read -r COMMIT_END REVEAL_END <<<"$(cast call "$TOURNAMENT" \
  'tasks(uint256)(address,uint64,uint64,uint32,uint32,uint128,uint128,uint256,bool)' "$TASK_ID" \
  --rpc-url "$RPC_URL" | sed -n '2p;3p' | tr '\n' ' ')"

MODE=commit forge script script/Mine.s.sol:Mine --rpc-url "$RPC_URL" --broadcast -g 130 2>&1 \
  | grep -E 'baseline|committed|Revert|Error' || exit 1

NOW=$(date +%s); WAIT=$((COMMIT_END - NOW + 2))
[ "$WAIT" -gt 0 ] && { echo "waiting ${WAIT}s for the reveal window"; sleep "$WAIT"; }

MODE=reveal forge script script/Mine.s.sol:Mine --rpc-url "$RPC_URL" --broadcast -g 130 2>&1 \
  | grep -E 'revealed|Revert|Error' || exit 1

NOW=$(date +%s); WAIT=$((REVEAL_END - NOW + 2))
[ "$WAIT" -gt 0 ] && { echo "waiting ${WAIT}s for settlement"; sleep "$WAIT"; }

[ -n "${FLAP_VAULT:-}" ] && MODE=collect forge script script/Mine.s.sol:Mine \
  --rpc-url "$RPC_URL" --broadcast -g 130 2>&1 | grep -E 'collected|Revert|Error'
