// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Tournament} from "../src/Tournament.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
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

        // There is no unconverted-tax leg any more, and its absence is the point. Flap's review
        // asked that vault funds never move to an address the project controls: what accumulates
        // there stays there, becomes BTCB through `triggerConversion`, and reaches miners through
        // `collect`. `withdrawUnconverted` was the path out to the curator and it is deleted, so
        // this script no longer touches the flap vault at all.
        //
        // What it still recovers is the project's own money: ASSAY posted as a task pot, returned
        // by `reclaim` on tasks nobody won. That never was vault tax.
        //
        // If value ever has to leave the vault, it leaves through Flap's Guardian —
        // `emergencyWithdrawNative` / `emergencyWithdrawToken` — and not through anything here.

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
        // The vault can now hold value the ledger never denominates — native coin forced in, or a
        // foreign token mis-sent. Both are recoverable by anyone to the fixed salvage address, and
        // an exit that did not report them would leave value behind while claiming to be finished.
        console2.log("sweepable native", vault.sweepableNative());
        require(vault.solvent(), "vault insolvent after exit");
    }
}
