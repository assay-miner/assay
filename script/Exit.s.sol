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

        // The tax that was never converted comes out first, because it is the only money here that
        // needs nobody's permission and no tournament outcome: `withdrawUnconverted` pays the fixed
        // curator address whatever BNB is not already promised to a scheduled swap. It reverts
        // while a task is still open, which is a wait and not a defect, so it cannot be allowed to
        // stop the reclaims below.
        //
        // Only the unconverted leg is recoverable this way. BTCB that a conversion already bought
        // leaves only through `collect`, to a miner the tournament scored — there is no path back
        // to the curator, by design.
        address flapVaultAddr = vm.envOr("FLAP_VAULT", address(0));
        if (flapVaultAddr != address(0)) {
            try AssayFlapVault(payable(flapVaultAddr)).withdrawUnconverted(0) returns (uint256 sent) {
                console2.log("unconverted BNB", sent);
            } catch {
                console2.log("unconverted BNB", "none free, or an epoch is still open");
            }
        }

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
