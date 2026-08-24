// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Tournament} from "../src/Tournament.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice Pulls every recoverable token back to the deployer.
/// @dev Deliberately unable to fail as a whole. Each task is reclaimed inside its own try/catch,
///      so one task that is still inside its claim window cannot block the tasks that are not.
///      There is no dry-run mode and no confirmation prompt: running this means taking the money
///      out now, and anything that makes that slower is a bug.
contract ExitAll is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        Tournament tournament = Tournament(vm.envAddress("TOURNAMENT"));
        IERC20 token = IERC20(vm.envAddress("TOKEN"));

        uint256 before = token.balanceOf(deployer);
        uint256 count = tournament.taskCount();
        uint256 recovered;
        uint256 skipped;

        vm.startBroadcast(pk);
        for (uint256 id = 1; id <= count; ++id) {
            try tournament.reclaim(id) returns (uint256 amount) {
                recovered += amount;
                console2.log("reclaimed task", id, amount);
            } catch {
                skipped++;
            }
        }
        vm.stopBroadcast();

        AssayVault vault = tournament.vault();
        uint256 afterBal = token.balanceOf(deployer);
        console2.log("tasks total     ", count);
        console2.log("tasks skipped   ", skipped);
        console2.log("reclaimed       ", recovered);
        console2.log("balance before  ", before);
        console2.log("balance after   ", afterBal);
        // What is left in the vault is other people's stake, not ours. Report both so the two
        // are never confused for one another.
        console2.log("vault held      ", token.balanceOf(address(vault)));
        console2.log("vault accounted ", vault.totalAccounted());
        console2.log("vault unattrib. ", vault.unaccounted());
        require(vault.solvent(), "vault insolvent after exit");
    }
}
