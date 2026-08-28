#!/usr/bin/env bash
# Runs the suite, retrying fork tests against other endpoints before calling them failures.
#
# Public BSC nodes prune state without warning, and forge reports that as `missing trie node` on a
# passing test. A suite that goes red for reasons unrelated to the code teaches you to ignore it
# going red, so an endpoint failure is retried elsewhere and only then reported.
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

MAINNET=(https://bsc-dataseed1.defibit.io https://bsc-rpc.publicnode.com https://bsc-dataseed.bnbchain.org)
TESTNET=(https://bsc-testnet-rpc.publicnode.com https://data-seed-prebsc-2-s1.bnbchain.org:8545 https://data-seed-prebsc-1-s2.bnbchain.org:8545)

for i in "${!MAINNET[@]}"; do
  OUT=$(BSC_RPC_URL="${MAINNET[$i]}" BSC_TESTNET_RPC="${TESTNET[$i]}" forge test "$@" 2>&1)
  echo "$OUT" | grep -E '^\[FAIL|tests passed' | tail -3

  # An endpoint that cannot serve state is not a failing test.
  if echo "$OUT" | grep -q 'missing trie node\|http2 error\|failed to get storage\|SendRequest'; then
    echo "  endpoint ${MAINNET[$i]} could not serve state — retrying elsewhere"
    continue
  fi
  echo "$OUT" | grep -q '^\[FAIL' && exit 1
  exit 0
done
echo "no endpoint served the state these fork tests need"
exit 2
