// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Crucible} from "../src/Crucible.sol";
import {TaskGen} from "../src/TaskGen.sol";

/// @notice The task is meant to be work for a program, not for a person.
///
/// @dev These assertions used to be made against a single static task checked into the repo, which
///      was the flaw: a fixed function is solved once and the answer replayed forever, so no
///      window is short enough to matter. They are now made against the generator that draws a
///      fresh program every epoch, because that is what actually runs.
contract MachineOnlyTest is BaseTest {
    uint256 constant OPS = 9;
    uint256 constant DRAWS = 10;
    /// @dev Mirrors GenTask's own gate. Changing it here without changing it there is the bug this
    ///      constant exists to make visible.
    uint256 constant MIN_MARGIN = 30;

    function _vectors(uint256 seed, TaskGen.Op[] memory ops)
        internal
        pure
        returns (Crucible.Vector[] memory v)
    {
        v = new Crucible.Vector[](8);
        for (uint256 i; i < v.length; ++i) {
            uint256 x = i == 0 ? 0 : (i == 1 ? 1 : (i == 2 ? type(uint256).max
                : uint256(keccak256(abi.encode(seed, "vec", i)))));
            v[i] = Crucible.Vector({
                input: abi.encodePacked(bytes32(x)),
                expected: keccak256(abi.encodePacked(bytes32(TaskGen.eval(ops, x))))
            });
        }
    }

    /// The literal translation of the epoch's program is the baseline, so submitting it earns zero.
    /// This is the whole difficulty: there is no credit for writing out what the task says.
    function test_TheObviousImplementationEarnsNothing() public {
        for (uint256 k; k < DRAWS; ++k) {
            uint256 seed = uint256(keccak256(abi.encode("obvious", k)));
            TaskGen.Op[] memory ops = TaskGen.draw(seed, OPS);
            Crucible.Vector[] memory v = _vectors(seed, ops);
            (bool ok, uint256 gas,) = harness.measure(TaskGen.compileNaive(ops), v, GAS_CAP);
            assertTrue(ok, "the literal translation fails its own vectors");
            // baselineGas is set to exactly this number, and the rule is `gasUsed < baselineGas`.
            assertFalse(gas < gas, "the literal translation must not score against itself");
        }
    }

    /// Every posted epoch must be winnable, or the tournament silently keeps the money.
    function test_EveryPostedEpochIsBeatable() public {
        uint256 posted;
        for (uint256 k; k < DRAWS; ++k) {
            uint256 seed = uint256(keccak256(abi.encode("beatable", k)));
            TaskGen.Op[] memory ops = TaskGen.draw(seed, OPS);
            Crucible.Vector[] memory v = _vectors(seed, ops);
            (bool okA, uint256 gA,) = harness.measure(TaskGen.compileNaive(ops), v, GAS_CAP);
            (bool okB, uint256 gB,) =
                harness.measure(TaskGen.compileTight(TaskGen.optimise(ops)), v, GAS_CAP);

            bool distinct = true;
            for (uint256 i; i < v.length; ++i) {
                for (uint256 j = i + 1; j < v.length; ++j) {
                    if (v[i].expected == v[j].expected) distinct = false;
                }
            }
            // GenTask only posts an instance that clears all of these. Anything it would post
            // must be beatable by at least the reference margin.
            if (okA && okB && distinct && gA > gB && gA - gB >= MIN_MARGIN) {
                ++posted;
                assertLt(gB, gA, "a posted epoch has no slack");
            }
        }
        assertGt(posted, 0, "no drawn instance was postable at all");
    }

    /// A program that collapses its input is worth nothing: the answer becomes a constant anyone
    /// can return without computing. Those instances must be rejected before posting, not scored.
    function test_CollapsedProgramsAreRejected() public pure {
        // AND against a single bit, then shifted past that bit: every input maps to zero.
        TaskGen.Op[] memory ops = new TaskGen.Op[](2);
        ops[0] = TaskGen.Op({kind: TaskGen.AND, c: uint256(1) << 62});
        ops[1] = TaskGen.Op({kind: TaskGen.SHR, c: 63});

        uint256 a = TaskGen.eval(ops, 1);
        uint256 b = TaskGen.eval(ops, type(uint256).max);
        assertEq(a, b, "the collapsing example stopped collapsing; pick another");
        // GenTask's `_informative` gate rejects exactly this shape.
    }

    /// @dev Windows are sized for a client, not for a person reading a freshly drawn program.
    ///
    ///      This used to be `vm.contains(gen, '"commitSeconds": 60')`, which is a SUBSTRING of
    ///      `"commitSeconds": 600` — so when the commit window went from 60 to 600 to close findings
    ///      021 and 024, the gate that exists to notice exactly that stayed green, and would have
    ///      stayed green at 6000 and 60000 too. It was guarding nothing for the whole time it read
    ///      as the thing guarding it.
    ///
    ///      It parses the number now and bounds it on both sides: at least the floor `Tournament`
    ///      enforces, and short enough that a human cannot read a freshly drawn nine-instruction
    ///      program and hand-optimise it inside the window.
    function test_TheWindowsAreMachineSized() public view {
        string memory gen = vm.readFile("script/GenTask.s.sol");
        uint256 commitSeconds = _jsonNumberIn(gen, '"commitSeconds": ');
        uint256 revealSeconds = _jsonNumberIn(gen, '"revealSeconds": ');

        assertGe(commitSeconds, tournament.MIN_COMMIT_SPAN(), "under the contract's commit floor");
        assertLe(commitSeconds, 30 minutes, "the commit window is no longer machine-scale");
        assertGe(revealSeconds, 30, "the reveal window is too short to land a transaction in");
        assertLe(revealSeconds, 30 minutes, "the reveal window is no longer machine-scale");
    }

    /// @dev Reads the digits following `key` in `hay`, stopping at the first non-digit. Written out
    ///      because the substring check it replaces is exactly the bug above.
    function _jsonNumberIn(string memory hay, string memory key) internal pure returns (uint256 n) {
        bytes memory h = bytes(hay);
        bytes memory k = bytes(key);
        for (uint256 i; i + k.length < h.length; ++i) {
            bool hit = true;
            for (uint256 j; j < k.length; ++j) {
                if (h[i + j] != k[j]) { hit = false; break; }
            }
            if (!hit) continue;
            uint256 p = i + k.length;
            require(h[p] >= 0x30 && h[p] <= 0x39, "no digits after the key");
            while (p < h.length && h[p] >= 0x30 && h[p] <= 0x39) {
                n = n * 10 + (uint8(h[p]) - 0x30);
                ++p;
            }
            return n;
        }
        revert("key not found");
    }
}
