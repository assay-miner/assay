#!/usr/bin/env bash
# Builds tasks/square.json. The chain only ever stores keccak256 of each expected output, so
# this script is the one place the answers exist in the clear — and they stay here.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

XS=(2 3 7 11 65535 4294967296)

INPUTS=""; EXPECTED=""
for x in "${XS[@]}"; do
  IN=$(printf '0x%064x' "$x")
  SQ=$(python3 -c "print('0x%064x' % ($x*$x))")
  H=$(cast keccak "$SQ")
  INPUTS="$INPUTS    \"$IN\",\n"
  EXPECTED="$EXPECTED    \"$H\",\n"
  echo "  $x^2 -> $H"
done
INPUTS=$(printf "$INPUTS" | sed '$ s/,$//')
EXPECTED=$(printf "$EXPECTED" | sed '$ s/,$//')

cat > tasks/square.json <<JSON
{
  "name": "square",
  "description": "Read a uint256 from calldata and return its square as 32 raw bytes.",
  "inputs": [
$INPUTS
  ],
  "expected": [
$EXPECTED
  ],
  "baselineGas": 2000,
  "gasCap": 100000,
  "commitSeconds": 3600,
  "revealSeconds": 3600,
  "pot": "100000000000000000000000"
}
JSON
echo "wrote tasks/square.json (${#XS[@]} vectors)"
