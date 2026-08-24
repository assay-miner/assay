// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Tournament} from "../src/Tournament.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Publishes one task from a JSON spec and escrows its pot.
/// @dev The spec carries output *hashes*, never outputs. That is not a size optimisation: a task
///      whose answers are readable on chain can be solved by echoing storage instead of computing.
contract PostTask is Script {
    error VectorCountMismatch(uint256 inputs, uint256 expected);
    error BaselineNotBeatable(uint32 baselineGas);

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
