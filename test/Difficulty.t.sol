// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Crucible} from "../src/Crucible.sol";
import {CrucibleHarness} from "./CrucibleHarness.sol";

/// @notice Measures candidate solutions so the baseline is set from data, not from a guess.
/// @dev The baseline is the difficulty knob and the rule is unforgiving: matching it or doing
///      worse scores zero. Setting it at the gas of the implementation a person would obviously
///      write is what makes the task machine-only — the obvious answer earns nothing, and only a
///      search that actually found something cheaper is paid.
contract DifficultyTest is Test {
    CrucibleHarness internal harness;
    Crucible.Vector[] internal vectors;

    function setUp() public {
        harness = new CrucibleHarness();
        uint256[8] memory xs = [uint256(2), 3, 7, 11, 0, 1, type(uint128).max, 65535];
        for (uint256 i; i < xs.length; ++i) {
            unchecked {
                vectors.push(Crucible.Vector({
                    input: abi.encodePacked(xs[i]),
                    expected: keccak256(abi.encodePacked(xs[i] * xs[i]))
                }));
            }
        }
    }

    function _m(string memory label, bytes memory code) internal {
        (bool ok, uint256 gas,) = harness.measure(code, vectors, 100_000);
        emit log_named_uint(string.concat(ok ? "PASS " : "FAIL ", label), gas);
    }

    function test_MeasureCandidates() public {
        // What a person writes first: PUSH1 0, CALLDATALOAD, DUP1, MUL, PUSH1 0, MSTORE, return.
        _m("obvious (PUSH1 offsets)", hex"600035800260005260206000f3");
        // The same idea with PUSH0 instead of PUSH1 0 — one byte and three gas cheaper each.
        _m("PUSH0 offsets", hex"5f3580025f5260205ff3");
        // And with MSIZE standing in for the return length, which is what the search finds.
        _m("PUSH0 + MSIZE", hex"5f3580025f52595ff3");
        // Deliberately wasteful, for the spread.
        _m("padded with dead code",
            hex"6000358002600052"
            hex"60005060005060005060005060005060005060005060005060005060005060206000f3");
    }
}
