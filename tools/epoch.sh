#!/usr/bin/env bash
# Runs one epoch: draw a fresh task, measure its baseline, post it, and point the epoch's tax at
# it. Intended to be run on a five-minute cadence.
#
# The seed is the latest block hash. That matters twice: we cannot shop for a program that suits
# an answer we already hold, and nobody can start searching before the block that names it exists.
# A task drawn any other way is a task somebody can precompute.
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

: "${RPC_URL:?RPC_URL is required}"
: "${TOURNAMENT:?TOURNAMENT is required}"
: "${TOKEN:?TOKEN is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"

SEED=$(cast block latest --json --rpc-url "$RPC_URL" | python3 -c 'import json,sys;print(json.load(sys.stdin)["hash"])')
[ -n "$SEED" ] || { echo "could not read a block hash"; exit 1; }
echo "seed  $SEED"

SEED="$SEED" OUT=tasks/epoch.json forge script script/GenTask.s.sol:GenTask 2>&1 \
  | grep -E '^  (draws|baselineGas|reference best|margin)' || { echo "task generation failed"; exit 1; }

python3 - <<'PY' || exit 1
import json,sys
d=json.load(open('tasks/epoch.json'))
# Refuse to post a task nothing can win, or one a constant answer wins.
assert d['baselineGas']>d['referenceGas'], 'no slack: baseline is not beatable'
assert len(set(d['expected']))==len(d['expected']), 'vectors collapse to the same output'
print(f"  margin {d['baselineGas']-d['referenceGas']} gas over {len(d['inputs'])} vectors")
PY

TASK_SPEC=tasks/epoch.json forge script script/PostTask.s.sol:PostTask \
  --rpc-url "$RPC_URL" --broadcast -g 130 2>&1 | tail -20
