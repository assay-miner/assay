// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {Crucible} from "../src/Crucible.sol";
import {TaskGen} from "../src/TaskGen.sol";
import {console2} from "forge-std/console2.sol";

/// @notice The baseline is measured in one place and enforced in another. If those two disagree,
///         every posted task is either unwinnable or trivially winnable.
contract MeasurementParityTest is BaseTest {
    function test_HarnessAgreesWithTheSettlementPath() public {
        uint256 seed = uint256(keccak256("parity"));
        TaskGen.Op[] memory ops = TaskGen.draw(uint256(keccak256(abi.encode(seed, uint256(0)))), 9);

        bytes[] memory ins = new bytes[](8);
        bytes32[] memory exp = new bytes32[](8);
        Crucible.Vector[] memory v = new Crucible.Vector[](8);
        for (uint256 i; i < 8; ++i) {
            uint256 x = i == 0 ? 0 : (i == 1 ? 1 : uint256(keccak256(abi.encode(seed, "vec", i))));
            ins[i] = abi.encodePacked(bytes32(x));
            exp[i] = keccak256(abi.encodePacked(bytes32(TaskGen.eval(ops, x))));
            v[i] = Crucible.Vector({input: ins[i], expected: exp[i]});
        }

        bytes memory code = TaskGen.compileNaive(ops);

        // What the task author measures.
        (bool okH, uint256 gasHarness,) = harness.measure(code, v, GAS_CAP);
        assertTrue(okH, "harness rejected the reference");

        // What settlement will actually record, through the same call the tournament makes.
        vm.prank(CURATOR);
        uint256 id = tournament.postTask(
            ins, exp, code, GAS_CAP, uint64(block.timestamp + 60), uint64(block.timestamp + 120), 0
        );
        (bool okC, uint256 gasChain,) = tournament.previewAssay(id, code);
        assertTrue(okC, "the settlement path rejected the reference");

        console2.log("harness gas   ", gasHarness);
        console2.log("settlement gas", gasChain);
        console2.log("delta         ", gasChain > gasHarness ? gasChain - gasHarness : gasHarness - gasChain);

        assertEq(gasHarness, gasChain, "the baseline is measured differently from how it is enforced");
    }
}
