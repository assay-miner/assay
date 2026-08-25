// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Tournament} from "../src/Tournament.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice Publishes one task, escrows its ASSAY pot, and puts the accumulated tax behind it.
///
/// @dev The spec carries output *hashes*, never outputs. That is not a size optimisation: a task
///      whose answers are readable on chain can be solved by echoing storage instead of computing.
///
///      Endowing happens here rather than in a command of its own because a task nobody has put
///      money behind is only half posted, and because the slippage floor has to come from a
///      quote taken moments before the swap. A floor a human types is a floor that was true
///      whenever they last looked.
contract PostTask is Script {
    error VectorCountMismatch(uint256 inputs, uint256 expected);
    error BaselineNotBeatable(uint32 baselineGas);
    error EndowMovedNothing(uint256 taskId);

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        Tournament tournament = Tournament(vm.envAddress("TOURNAMENT"));
        IERC20 token = IERC20(vm.envAddress("TOKEN"));

        string memory json = vm.readFile(vm.envString("TASK_SPEC"));

        bytes[] memory inputs = vm.parseJsonBytesArray(json, ".inputs");
        bytes32[] memory expected = vm.parseJsonBytes32Array(json, ".expected");
        if (inputs.length != expected.length) {
            revert VectorCountMismatch(inputs.length, expected.length);
        }

        uint32 baselineGas = uint32(vm.parseJsonUint(json, ".baselineGas"));
        uint32 gasCap = uint32(vm.parseJsonUint(json, ".gasCap"));
        uint256 pot = vm.parseJsonUint(json, ".pot");
        uint64 commitEnd = uint64(block.timestamp + vm.parseJsonUint(json, ".commitSeconds"));
        uint64 revealEnd = uint64(commitEnd + vm.parseJsonUint(json, ".revealSeconds"));

        // A baseline of zero would make every submission unbeatable and silently burn the pot.
        if (baselineGas == 0) revert BaselineNotBeatable(baselineGas);

        // Approval goes to the vault, not the tournament: the vault pulls the escrow directly,
        // so the pot never sits inside a logic contract even for a single call.
        vm.startBroadcast(pk);
        token.approve(address(tournament.vault()), pot);
        uint256 taskId = tournament.postTask(
            inputs, expected, baselineGas, gasCap, commitEnd, revealEnd, uint128(pot)
        );
        // The tax layer. Absent before the token has been launched, and absent on a chain where
        // nothing has traded yet — neither is a failure, so neither aborts the post.
        address flapVaultAddr = vm.envOr("FLAP_VAULT", address(0));
        if (flapVaultAddr != address(0)) {
            AssayFlapVault flap = AssayFlapVault(payable(flapVaultAddr));
            uint256 free = flap.unassigned();
            uint256 want = vm.envOr("ENDOW_BNB", free);
            if (want > free) want = free;

            if (want > 0) {
                // The floor is derived from a quote taken in this same script, moments before the
                // swap, and tightened by the tolerance the operator set rather than by a number
                // they had to work out.
                uint256 bps = vm.envOr("MAX_SLIPPAGE_BPS", uint256(200));
                uint256 floor = (flap.quote(want) * (10_000 - bps)) / 10_000;

                uint256 got = flap.endow(taskId, want, floor);
                if (got == 0) revert EndowMovedNothing(taskId);

                console2.log("endowed bnb ", want);
                console2.log("floor btcb  ", floor);
                console2.log("bounty btcb ", got);
            } else {
                console2.log("endowed     ", "no unconverted tax has arrived yet");
            }
        }

        vm.stopBroadcast();

        console2.log("task        ", taskId);
        console2.log("vectors     ", inputs.length);
        console2.log("baselineGas ", baselineGas);
        console2.log("gasCap      ", gasCap);
        console2.log("pot         ", pot);
        console2.log("commitEnd   ", commitEnd);
        console2.log("revealEnd   ", revealEnd);
    }
}
