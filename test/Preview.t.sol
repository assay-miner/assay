// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {Tournament} from "../src/Tournament.sol";

/// @notice The dry run must agree with settlement exactly, or it is worse than useless: a miner
///         who trusts a number that is two gas off spends a whole reveal to find out.
contract PreviewTest is BaseTest {
    function _previewOf(bytes memory runtime) internal returns (bool, uint256, uint256) {
        return tournament.previewAssay(taskId, runtime);
    }

    /// @dev The property under test: preview == what the chain records. Not "close to".
    function test_PreviewMatchesSettlementExactly() public {
        (bool okPreview, uint256 gasPreview, uint256 scorePreview) = _previewOf(Bytecode.tight());
        assertTrue(okPreview, "preview says it passes");

        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.tight(), bytes32("a"));

        (,, uint32 gasRecorded, uint128 scoreRecorded,,) = tournament.submissions(taskId, ALICE);
        assertEq(gasPreview, gasRecorded, "gas is identical, not approximate");
        assertEq(scorePreview, scoreRecorded, "score is identical");
    }

    function test_PreviewAgreesOnAPaddedSubmissionToo() public {
        (, uint256 gasPreview,) = _previewOf(Bytecode.padded());

        _enroll(BOB, AGENT_BOB);
        _commit(BOB, AGENT_BOB, Bytecode.padded(), bytes32("b"));
        vm.warp(commitEnd);
        _reveal(BOB, Bytecode.padded(), bytes32("b"));

        (,, uint32 gasRecorded,,,) = tournament.submissions(taskId, BOB);
        assertEq(gasPreview, gasRecorded, "gas identical for the padded one as well");
    }

    function test_PreviewRejectsAWrongAnswer() public {
        (bool passed, uint256 gasUsed, uint256 score) = _previewOf(Bytecode.wrong());
        assertFalse(passed, "wrong answer does not pass");
        assertEq(gasUsed, 0, "no meaningful gas for a failure");
        assertEq(score, 0, "and no score");
    }

    function test_PreviewRejectsARevertingSubmission() public {
        (bool passed,, uint256 score) = _previewOf(Bytecode.reverting());
        assertFalse(passed, "a reverting submission does not pass");
        assertEq(score, 0, "and no score");
    }

    /// A dry run must not be able to stand in for a commitment.
    function test_PreviewWritesNothing() public {
        _enroll(ALICE, AGENT_ALICE);
        uint256 accountedBefore = vault.totalAccounted();
        (,,, uint256 totalScoreBefore,) = _taskCore();

        tournament.previewAssay(taskId, Bytecode.tight());

        (,,, uint256 totalScoreAfter,) = _taskCore();
        (bytes32 commitment,,,, bool revealed,) = tournament.submissions(taskId, ALICE);
        assertEq(totalScoreAfter, totalScoreBefore, "no score was banked");
        assertEq(commitment, bytes32(0), "no commitment was created");
        assertFalse(revealed, "nothing was revealed");
        assertEq(vault.totalAccounted(), accountedBefore, "no value moved");
    }

    function test_PreviewOnAnUnknownTaskReverts() public {
        vm.expectRevert(bytes(unicode"No such task / 该任务不存在"));
        tournament.previewAssay(999, Bytecode.tight());
    }

    function _taskCore()
        internal
        view
        returns (uint32 gasCap, uint32 baselineGas, uint128 pot, uint256 totalScore, bool reclaimed)
    {
        (, , , gasCap, baselineGas, pot, , totalScore, reclaimed) = tournament.tasks(taskId);
    }
}
