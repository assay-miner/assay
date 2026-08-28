// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {TaxTokenMock} from "../test/TaxTokenMock.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";

/// @notice Stands up the stack plus a Flap vault, without going through the portal.
///
/// @dev The portal path is proven separately, on a mainnet fork, in `test/FlapGate.t.sol` and
///      `script/FlapDemo.s.sol` — an unregistered factory launches and the portal records the
///      vault. This script exists because the *rendered page* does not depend on who called the
///      constructor: the vault bytecode, its schema and its behaviour are identical either way,
///      and testnet keeps fork state alive long enough to drive a full economic cycle through it
///      where a public mainnet node does not.
contract FlapVaultDemo is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address registry = block.chainid == 56
            ? 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
            : 0x8004A818BFB912233c491871b3d84c89A494BD9e;

        vm.startBroadcast(pk);
        TaxTokenMock token = new TaxTokenMock(me, 1_000_000_000e18);
        AssayVault custody = new AssayVault(IERC20(address(token)), me);
        AgentRoster roster = new AgentRoster(IIdentityRegistry(registry), custody, 1000e18, me);
        Tournament tournament = new Tournament(custody, roster, me);
        custody.addController(address(roster));
        custody.addController(address(tournament));
        custody.freeze();
        roster.setConsumer(address(tournament));

        // taxToken is recorded, never called — the portal passes a predicted address too.
        AssayFlapVault flapVault = new AssayFlapVault(tournament, address(token), me);
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
