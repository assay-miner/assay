// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {TaskGen} from "../src/TaskGen.sol";

/// @notice Emits the compiler's own answers so the JavaScript client can be checked against them.
/// @dev The client re-implements TaskGen. "It looks equivalent" is not a check; this is.
contract ParityVectors is Script {
    function run() external {
        uint256 n = vm.envOr("N", uint256(40));
        string memory out = "[";
        for (uint256 k; k < n; ++k) {
            uint256 seed = uint256(keccak256(abi.encode("parity", k)));
            TaskGen.Op[] memory ops = TaskGen.draw(seed, 9);

            string memory evals = "";
            for (uint256 i; i < 5; ++i) {
                uint256 x = i == 0 ? 0 : (i == 1 ? 1 : (i == 2 ? type(uint256).max
                    : uint256(keccak256(abi.encode(seed, i)))));
                evals = string.concat(
                    evals, i == 0 ? "" : ",",
                    '["', vm.toString(bytes32(x)), '","', vm.toString(bytes32(TaskGen.eval(ops, x))), '"]'
                );
            }

            string memory prog = "";
            for (uint256 i; i < ops.length; ++i) {
                prog = string.concat(
                    prog, i == 0 ? "" : ",",
                    '[', vm.toString(uint256(ops[i].kind)), ',"', vm.toString(bytes32(ops[i].c)), '"]'
                );
            }

            out = string.concat(
                out, k == 0 ? "" : ",",
                '{"seed":"', vm.toString(bytes32(seed)),
                '","program":[', prog,
                '],"evals":[', evals,
                '],"naive":"', vm.toString(TaskGen.compileNaive(ops)),
                '","tight":"', vm.toString(TaskGen.compileTight(TaskGen.optimise(ops))),
                '"}'
            );
        }
        vm.writeFile("tasks/parity.json", string.concat(out, "]"));
    }
}
