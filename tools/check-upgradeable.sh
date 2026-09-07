#!/usr/bin/env bash
# Two things the compiler cannot refuse, now that every contract sits behind a beacon.
set -euo pipefail
cd "$(dirname "$0")/.."

bad=0

# 1. `new PriceGuard()` is the ONE stale call site the beacon conversion left compiling. Its
#    constructor took no arguments before and takes none after, so every other contract's old call
#    site died with "Wrong argument count" and this one did not. What it returns is a brick: router
#    and reward are zero, and `_disableInitializers()` in the constructor means it can never be
#    initialized afterwards. There is no runtime error until somebody converts tax at a launch.
#
#    Same for the other six: constructing an implementation directly and using it as if it were the
#    contract is always wrong now. Everything goes through script/Stack.sol.
echo "→ direct implementation construction outside script/Stack.sol"
HITS=$(grep -rn 'new \(PriceGuard\|AssayVault\|AgentRoster\|Tournament\|AssayFlapVault\|AssayFlapFactory\|TaskGenerator\)()' \
  src/ test/ script/ 2>/dev/null \
  | grep -v '^script/Stack.sol' \
  | grep -v 'test/UpgradeAuthority.t.sol' \
  | grep -v 'address(new ' \
  || true)
if [ -n "$HITS" ]; then
  echo "$HITS" | sed 's/^/    /'
  echo "    ^ these build an uninitialized implementation, not a working contract."
  echo "      Use script/Stack.sol. If a bare implementation is genuinely wanted (to upgrade a"
  echo "      beacon to, or to assert it is a brick), wrap it as address(new X())."
  bad=1
else
  echo "    ok"
fi

# 2. The storage layout is permanent from the moment a beacon points at code. This repository
#    vendors TWO Initializable implementations that both resolve through existing remappings:
#    openzeppelin-contracts-upgradeable 4.9.6 declares `_initialized`/`_initializing` as real
#    storage in slot 0, and openzeppelin-contracts 5.4.0 uses an ERC-7201 namespace and declares
#    none. Changing which one a contract imports moves every variable that shares slot 0 — silently,
#    on a live proxy, with everything still compiling. foundry.toml already records that this repo
#    was bitten once by these overlapping prefixes.
echo "→ Initializable resolves to the 4.9.x storage layout"
for f in src/PriceGuard.sol src/AssayVault.sol src/AgentRoster.sol src/Tournament.sol \
         src/AssayFlapVault.sol src/AssayFlapFactory.sol src/TaskGenerator.sol; do
  if ! grep -q 'import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";' "$f"; then
    echo "    $f does not import Initializable from @openzeppelin-contracts-upgradeable/"
    bad=1
  fi
done
[ "$bad" = 0 ] && echo "    ok"

exit $bad
