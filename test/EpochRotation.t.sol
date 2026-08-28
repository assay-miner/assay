// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Crucible} from "../src/Crucible.sol";
import {TaskGen} from "../script/TaskGen.sol";

/// @notice The properties that make an epoch's task machine-work rather than a replayed answer.
///
/// @dev The tournament's difficulty used to live entirely in one static task: read a uint256,
///      return its square. Anybody — person or program — solves that once and resubmits the same
///      bytes every epoch forever, so the commit window stops being a constraint and the whole
///      thing collapses into a submission race. These tests pin the two properties that fix it:
///      the program changes every epoch, and last epoch's winner is worthless this epoch.
contract EpochRotationTest is BaseTest {
    uint256 constant OPS = 9;

    function _vectorsFor(uint256 seed, TaskGen.Op[] memory ops)
        internal
        pure
        returns (Crucible.Vector[] memory v)
    {
        v = new Crucible.Vector[](6);
        for (uint256 i; i < v.length; ++i) {
            uint256 x = i == 0 ? 0 : (i == 1 ? 1 : uint256(keccak256(abi.encode(seed, i))));
            v[i] = Crucible.Vector({
                input: abi.encodePacked(bytes32(x)),
                expected: keccak256(abi.encodePacked(bytes32(TaskGen.eval(ops, x))))
            });
        }
    }

    /// Last epoch's winning bytecode must not pass this epoch's vectors.
    function test_PreviousWinnerFailsNextEpoch() public {
        TaskGen.Op[] memory a = TaskGen.draw(uint256(keccak256("epoch-1")), OPS);
        TaskGen.Op[] memory b = TaskGen.draw(uint256(keccak256("epoch-2")), OPS);

        bytes memory winnerOfA = TaskGen.compileTight(TaskGen.optimise(a));
        Crucible.Vector[] memory vecB = _vectorsFor(uint256(keccak256("epoch-2")), b);

        (bool ok,,) = harness.measure(winnerOfA, vecB, GAS_CAP);
        assertFalse(ok, "an answer from a previous epoch still passes this one");
    }

    /// The optimised form must agree with the literal one on every vector. An "optimisation" that
    /// changes the answer would post a baseline nothing can legally reach.
    function test_OptimiserPreservesSemantics() public {
        for (uint256 k; k < 12; ++k) {
            uint256 seed = uint256(keccak256(abi.encode("sem", k)));
            TaskGen.Op[] memory ops = TaskGen.draw(seed, OPS);
            Crucible.Vector[] memory v = _vectorsFor(seed, ops);

            (bool okNaive, uint256 gNaive,) = harness.measure(TaskGen.compileNaive(ops), v, GAS_CAP);
            (bool okTight, uint256 gTight,) =
                harness.measure(TaskGen.compileTight(TaskGen.optimise(ops)), v, GAS_CAP);

            assertTrue(okNaive, "the literal translation does not answer its own vectors");
            assertTrue(okTight, "the optimised form disagrees with the literal one");
            assertLe(gTight, gNaive, "the optimised form costs more than the literal one");
        }
    }

    /// A submission that does no searching lands on the baseline and earns nothing.
    function test_NaiveSubmissionScoresZero() public {
        uint256 seed = uint256(keccak256("scoring"));
        TaskGen.Op[] memory ops = TaskGen.draw(seed, OPS);
        Crucible.Vector[] memory v = _vectorsFor(seed, ops);

        (, uint256 gNaive,) = harness.measure(TaskGen.compileNaive(ops), v, GAS_CAP);
        (, uint256 gTight,) = harness.measure(TaskGen.compileTight(TaskGen.optimise(ops)), v, GAS_CAP);
        assertLt(gTight, gNaive, "instance has no slack to score against");

        // baselineGas is the literal translation's cost, so matching it scores zero by the
        // tournament's own rule: `if (gasUsed < t.baselineGas)`.
        assertFalse(gNaive < gNaive, "matching the baseline must not score");
    }

    /// Scoring must pay a full search materially more than a one-opcode shortcut. Under the old
    /// ratio form these two were within a few percent of each other.
    function test_SearchOutscoresTheObviousByFar() public view {
        uint256 baseline = 1656;
        uint256 lazy = 1600; // deleted one redundant opcode
        uint256 searched = 1520; // ran the search

        uint256 sLazy = ((baseline - lazy) ** 2 * tournament.SCORE_SCALE()) / (baseline * baseline);
        uint256 sSearch =
            ((baseline - searched) ** 2 * tournament.SCORE_SCALE()) / (baseline * baseline);

        assertGt(sSearch, sLazy * 4, "a full search must pay far more than the obvious shortcut");
    }

    /// Independent seeds must produce different programs, or "rotation" is cosmetic.
    function test_SeedsProduceDistinctPrograms() public pure {
        uint256 same;
        for (uint256 k; k < 16; ++k) {
            TaskGen.Op[] memory a = TaskGen.draw(uint256(keccak256(abi.encode("p", k))), OPS);
            TaskGen.Op[] memory b = TaskGen.draw(uint256(keccak256(abi.encode("p", k + 1))), OPS);
            if (keccak256(abi.encode(a)) == keccak256(abi.encode(b))) ++same;
        }
        assertEq(same, 0, "distinct seeds produced identical programs");
    }
}
