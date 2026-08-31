// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Hand-written EVM runtime payloads used as miner submissions in the tests.
/// @dev These are the shape a real miner submits: raw runtime bytecode, no constructor, no
///      Solidity wrapper. The task they answer is "read a uint256 from calldata, return its
///      square", which is small enough that the gas difference between a tight and a padded
///      implementation is unambiguous.
library Bytecode {
    /// PUSH1 0 | CALLDATALOAD | DUP1 | MUL | PUSH1 0 | MSTORE | PUSH1 32 | PUSH1 0 | RETURN
    function tight() internal pure returns (bytes memory) {
        return hex"600035800260005260206000f3";
    }

    /// The same computation with ten PUSH1 0/POP pairs bolted on: identical output, more gas.
    function padded() internal pure returns (bytes memory) {
        return hex"6000358002600052"
            hex"60005060005060005060005060005060005060005060005060005060005060206000f3";
    }

    /// The same computation again, more wastefully still. This is what a task's baseline is
    /// measured from: the chain records the reference's own cost, so a reference must be worse
    /// than anything a miner would submit or nothing can score.
    function verbose() internal pure returns (bytes memory) {
        return hex"6000358002600052"
            hex"6000506000506000506000506000506000506000506000506000506000506000506000506000506000506000506000506000506000506000506000"
            hex"60206000f3";
    }

    /// Returns the input unchanged instead of squaring it: passes nothing.
    function wrong() internal pure returns (bytes memory) {
        return hex"600035600052" hex"60206000f3";
    }

    /// Reverts immediately.
    function reverting() internal pure returns (bytes memory) {
        return hex"60006000fd";
    }
}
