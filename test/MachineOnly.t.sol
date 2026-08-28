// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Crucible} from "../src/Crucible.sol";
import {CrucibleHarness} from "./CrucibleHarness.sol";

/// @notice Holds the shipped task spec to the claim written in its own notes.
///
/// @dev The spec says the obvious implementation earns nothing and only a search is paid. That is
///      a claim about two specific numbers — the baseline, and what the obvious answer costs —
///      and the two drift apart the moment anyone edits a vector, adds one, or changes the
///      baseline. Then the task quietly becomes solvable by hand and nothing says so.
///
///      These read the spec off disk rather than restating it, so the file is what is tested.
contract MachineOnlyTest is Test {
    /// The implementation a person writes first: PUSH1 0, CALLDATALOAD, DUP1, MUL, PUSH1 0,
    /// MSTORE, PUSH1 32, PUSH1 0, RETURN.
    bytes internal constant OBVIOUS = hex"600035800260005260206000f3";
    /// What the search actually finds: PUSH0 for the offsets and MSIZE for the return length.
    bytes internal constant SEARCHED = hex"5f3580025f52595ff3";

    CrucibleHarness internal harness;
    Crucible.Vector[] internal vectors;
    uint32 internal baselineGas;
    uint32 internal gasCap;

    function setUp() public {
        harness = new CrucibleHarness();
        string memory spec = vm.readFile("tasks/square.json");
        bytes[] memory inputs = vm.parseJsonBytesArray(spec, ".inputs");
        bytes32[] memory expected = vm.parseJsonBytes32Array(spec, ".expected");
        baselineGas = uint32(vm.parseJsonUint(spec, ".baselineGas"));
        gasCap = uint32(vm.parseJsonUint(spec, ".gasCap"));
        for (uint256 i; i < inputs.length; ++i) {
            vectors.push(Crucible.Vector({input: inputs[i], expected: expected[i]}));
        }
    }

    function _gasOf(bytes memory code) internal returns (uint256) {
        (bool ok, uint256 gas,) = harness.measure(code, vectors, gasCap);
        assertTrue(ok, "candidate does not pass the task's own vectors");
        return gas;
    }

    /// @notice The answer a person would submit must score zero.
    function test_TheObviousImplementationEarnsNothing() public {
        uint256 obvious = _gasOf(OBVIOUS);
        assertGe(
            obvious,
            baselineGas,
            "the obvious implementation beats the baseline: this task is solvable by hand"
        );
        emit log_named_uint("obvious costs", obvious);
        emit log_named_uint("baseline     ", baselineGas);
    }

    /// @notice And a search must still be able to score, or the task is unwinnable.
    function test_ASearchedAnswerStillScores() public {
        uint256 searched = _gasOf(SEARCHED);
        assertLt(searched, baselineGas, "nothing beats the baseline: the pot can never be won");
        emit log_named_uint("searched costs", searched);
    }

    /// @notice The margin is thin on purpose, and worth knowing if it ever widens.
    function test_TheMarginIsTight() public {
        uint256 margin = _gasOf(OBVIOUS) - _gasOf(SEARCHED);
        emit log_named_uint("margin, gas", margin);
        assertLt(margin, 100, "the gap grew wide enough to be found by hand");
    }

    /// @notice The vectors must reach the cases an answer would otherwise special-case away.
    function test_TheVectorsCoverTheEdges() public view {
        bool zero;
        bool one;
        bool huge;
        for (uint256 i; i < vectors.length; ++i) {
            uint256 x = abi.decode(vectors[i].input, (uint256));
            if (x == 0) zero = true;
            if (x == 1) one = true;
            if (x > type(uint64).max) huge = true;
        }
        assertTrue(zero, "no zero vector, so an answer can return calldata untouched");
        assertTrue(one, "no unit vector");
        assertTrue(huge, "no large vector, so an answer can skip the wide multiply");
        assertGe(vectors.length, 8, "too few vectors to price an implementation honestly");
    }

    /// @notice Five minutes each way, which a person does not finish and a client does in seconds.
    function test_TheWindowsAreMachineSized() public view {
        string memory spec = vm.readFile("tasks/square.json");
        assertLe(vm.parseJsonUint(spec, ".commitSeconds"), 300, "commit window opened up");
        assertLe(vm.parseJsonUint(spec, ".revealSeconds"), 300, "reveal window opened up");
    }
}
