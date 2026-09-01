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
    error BaselineDisagrees(uint32 stated, uint32 measured);

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

        // The baseline is measured on chain from this, not read from the file. The file still
        // carries the number the generator measured locally, and the assertion after the post
        // checks the two agree — a disagreement means the spec and the chain do not describe the
        // same program.
        bytes memory referenceRuntime = vm.parseJsonBytes(json, ".referenceRuntime");
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
            inputs, expected, referenceRuntime, gasCap, commitEnd, revealEnd, uint128(pot)
        );
        (,,,, uint32 measured,,,,) = tournament.tasks(taskId);
        if (measured != baselineGas) revert BaselineDisagrees(baselineGas, measured);
        // The tax layer. Absent before the token has been launched, and absent on a chain where
        // nothing has traded yet — neither is a failure, so neither aborts the post.
        address flapVaultAddr = vm.envOr("FLAP_VAULT", address(0));
        if (flapVaultAddr != address(0)) {
            AssayFlapVault flap = AssayFlapVault(payable(flapVaultAddr));

            // Put the pool behind this task. Without this the tax converts into `rewardPool` and
            // stops there: `bounty` stays zero, `collectable` returns zero, and `collect` reverts
            // for the winner of a task that was funded on paper. Nothing called this in production
            // — only tests did — so the loop had never actually closed.
            //
            // The pool this draws on is what *earlier* epochs converted, not the conversion armed
            // below. That one lands five minutes from now, long after a sixty-second task has
            // settled, so it belongs to the next task and not this one.
            uint256 pool = flap.rewardPool();
            if (pool > 0) {
                uint256 funded = flap.fundTaskFromPool(taskId);
                console2.log("funded       ", funded);
            } else {
                console2.log("funded       ", "pool is empty; nothing converted yet");
            }

            uint256 free = flap.freeTax();
            uint256 want = vm.envOr("ENDOW_BNB", free);
            if (want > free) want = free;

            if (want > 0) {
                // The floor is derived from a quote taken in this same script, moments before the
                // swap, and tightened by the tolerance the operator set rather than by a number
                // Nothing is priced here any more. The vault derives the amount, the task and
                // the floor from its own state, so this script has no numbers left to get wrong —
                // and neither does anyone else who calls it.
                uint256 fee = flap.schedulerFee();
                uint256 requestId = flap.triggerConversion{value: fee}();

                console2.log("scheduled    ", "vault-derived chunk and floor; no task named");
                console2.log("request id   ", requestId);
                console2.log("scheduler fee", fee);
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
