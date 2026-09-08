// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Stack} from "./Stack.sol";
import {TaxTokenMock} from "../test/TaxTokenMock.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";

/// @notice Stands up the stack plus a Flap vault, without going through the portal.
///
/// @dev The portal path is proven separately, on a mainnet fork, in `test/FlapGate.t.sol` and
///      `script/FlapDemo.s.sol` — an unregistered factory launches and the portal records the
///      vault. This script exists because the *rendered page* does not depend on who created the
///      vault: the implementation behind it, its schema and its behaviour are identical either
///      way, and testnet keeps fork state alive long enough to drive a full economic cycle
///      through it where a public mainnet node does not.
contract FlapVaultDemo is Script {
    /// @dev This fixture never posts on the drawn lane, so the generator is a placeholder.
    ///      Naming it says that on purpose rather than leaving a bare address to be read as real.
    address internal constant NO_DRAWN_LANE = address(0xDEAD);

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address registry = block.chainid == 56
            ? 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
            : 0x8004A818BFB912233c491871b3d84c89A494BD9e;
        // Flap requires every contract to be upgradeable from a beacon their Guardian owns, so
        // nothing here is a bare `new` any more — each piece is an implementation, a beacon and an
        // initialized proxy, assembled by script/Stack.sol. Resolved by chain id the same way the
        // registry above is, and to the same addresses VaultBase and Tournament resolve.
        address guardian = block.chainid == 56
            ? 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b
            : 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;

        vm.startBroadcast(pk);
        TaxTokenMock token = new TaxTokenMock(me, 1_000_000_000e18);
        // `me` twice: the salvage destination, and the deployer the initializer records. The
        // second used to be `msg.sender` read inside the constructor, which an initializer behind
        // a proxy cannot rely on — the broadcasting key has to be named rather than inferred.
        AssayVault custody = Stack.newVault(guardian, address(token), me, me);
        AgentRoster roster = Stack.newRoster(guardian, registry, custody, 1000e18, me);
        Tournament tournament = Stack.newTournament(guardian, custody, roster, me, NO_DRAWN_LANE);
        custody.addController(address(roster));
        custody.addController(address(tournament));
        custody.freeze();
        roster.setConsumer(address(tournament));

        PriceGuard priceGuard = Stack.newPriceGuard(guardian);
        // taxToken is recorded, never called — the portal passes a predicted address too.
        AssayFlapVault flapVault =
            Stack.newFlapVault(guardian, tournament, address(token), priceGuard);
        vm.stopBroadcast();

        string memory json = "d";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "deployer", me);
        vm.serializeAddress(json, "identityRegistry", registry);
        vm.serializeAddress(json, "token", address(token));
        vm.serializeAddress(json, "vault", address(custody));
        vm.serializeAddress(json, "roster", address(roster));
        vm.serializeAddress(json, "tournament", address(tournament));
        string memory out = vm.serializeAddress(json, "flapVault", address(flapVault));
        vm.writeJson(out, "deployments/flap-vault-demo.json");

        console2.log("tournament ", address(tournament));
        console2.log("flapVault  ", address(flapVault));
    }
}
