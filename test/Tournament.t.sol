// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {Crucible} from "../src/Crucible.sol";
import {Tournament} from "../src/Tournament.sol";
import {AgentRoster} from "../src/AgentRoster.sol";

contract TournamentTest is BaseTest {
    // -----------------------------------------------------------------------------------
    // The mechanism actually measures work
    // -----------------------------------------------------------------------------------

    /// @dev The whole protocol rests on this: a tighter implementation must measurably cost less
    ///      gas than a padded one that computes the identical answer.
    function test_TighterImplementationMeasuresLower() public {
        (bool okTight, uint256 gasTight,) = harness.measure(Bytecode.tight(), _vectors(), GAS_CAP);
        (bool okPadded, uint256 gasPadded,) = harness.measure(Bytecode.padded(), _vectors(), GAS_CAP);

        assertTrue(okTight, "tight must pass");
        assertTrue(okPadded, "padded must pass");
        assertLt(gasTight, gasPadded, "optimisation must show up on the meter");
        emit log_named_uint("tight gas", gasTight);
        emit log_named_uint("padded gas", gasPadded);
    }

    /// @dev Measurement must be deterministic, or scores are noise.
    function test_MeasurementIsDeterministic() public {
        (, uint256 a,) = harness.measure(Bytecode.tight(), _vectors(), GAS_CAP);
        (, uint256 b,) = harness.measure(Bytecode.tight(), _vectors(), GAS_CAP);
        assertEq(a, b, "same bytecode must meter identically");
    }

    function test_HappyPath_TwoMinersSplitPotByScore() public {
        _enroll(ALICE, AGENT_ALICE);
        _enroll(BOB, AGENT_BOB);

        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        _commit(BOB, AGENT_BOB, Bytecode.padded(), bytes32("b"));

        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.tight(), bytes32("a"));
        _reveal(BOB, Bytecode.padded(), bytes32("b"));

        (,,,,,,, uint256 totalScore,) = tournament.tasks(taskId);
        assertGt(totalScore, 0, "someone must have scored");

        (, , uint32 aliceGas, uint128 aliceScore, ,) = tournament.submissions(taskId, ALICE);
        (, , uint32 bobGas, uint128 bobScore, ,) = tournament.submissions(taskId, BOB);
        assertLt(aliceGas, bobGas, "alice used less gas");
        assertGt(aliceScore, bobScore, "less gas must score higher");

        vm.warp(revealEnd);
        vm.prank(ALICE);
        uint256 alicePaid = tournament.claim(taskId);
        vm.prank(BOB);
        uint256 bobPaid = tournament.claim(taskId);

        assertGt(alicePaid, bobPaid, "better miner is paid more");
        assertLe(alicePaid + bobPaid, POT, "payouts cannot exceed the pot");
        assertEq(token.balanceOf(ALICE) - MIN_STAKE * 9, alicePaid, "alice received her claim");
    }

    // -----------------------------------------------------------------------------------
    // Correctness gate — proven red
    // -----------------------------------------------------------------------------------

    /// @dev Break what the gate guards: submit code that returns the input instead of its
    ///      square. It must score zero, not "mostly right".
    function test_WrongOutputScoresZero() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.wrong(), bytes32("a"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.wrong(), bytes32("a"));

        (,,, uint128 score,,) = tournament.submissions(taskId, ALICE);
        assertEq(score, 0, "a wrong answer must earn nothing");

        vm.warp(revealEnd);
        vm.prank(ALICE);
        vm.expectRevert(Tournament.NoScore.selector);
        tournament.claim(taskId);
    }

    function test_RevertingSubmissionScoresZero() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.reverting(), bytes32("a"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.reverting(), bytes32("a"));

        (,,, uint128 score,,) = tournament.submissions(taskId, ALICE);
        assertEq(score, 0, "a reverting submission must earn nothing");
    }

    /// @dev A submission that merely matches the baseline has not mined anything.
    function test_MatchingBaselineEarnsNothing() public {
        // Re-post a task whose baseline is exactly the reference cost.
        vm.startPrank(CURATOR);
        token.approve(address(tournament), POT);
        uint256 strictTask = tournament.postTask(
            inputs, expected, uint32(referenceGas), GAS_CAP, commitEnd, revealEnd, POT
        );
        vm.stopPrank();

        _enroll(ALICE, AGENT_ALICE);
        bytes32 salt = bytes32("a");
        vm.prank(ALICE);
        tournament.commit(strictTask, _commitment(Bytecode.padded(), salt, AGENT_ALICE));
        vm.warp(commitEnd);
        vm.prank(ALICE);
        tournament.reveal(strictTask, Bytecode.padded(), salt);

        (,, uint32 gasUsed, uint128 score,,) = tournament.submissions(strictTask, ALICE);
        assertEq(gasUsed, referenceGas, "reference must meter at the baseline");
        assertEq(score, 0, "matching the baseline is not an improvement");
    }

    // -----------------------------------------------------------------------------------
    // Anti-plagiarism — the reason commit-reveal exists
    // -----------------------------------------------------------------------------------

    /// @dev Carol watches Alice reveal and tries to replay the exact same (runtime, salt).
    ///      Her own commitment hashes under *her* agent id, so it cannot match.
    function test_StolenRevealDoesNotMatchAnotherAgentsCommitment() public {
        _enroll(ALICE, AGENT_ALICE);
        _enroll(CAROL, AGENT_CAROL);

        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        // Carol has to commit to something before seeing anything; she guesses the padded one.
        _commit(CAROL, AGENT_CAROL, Bytecode.padded(), bytes32("c"));

        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.tight(), bytes32("a"));

        // Now Carol has Alice's winning bytecode and salt in the clear. It does her no good.
        vm.prank(CAROL);
        vm.expectRevert(Tournament.CommitmentMismatch.selector);
        tournament.reveal(taskId, Bytecode.tight(), bytes32("a"));
    }

    function test_CannotCommitTwice() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        vm.prank(ALICE);
        vm.expectRevert(Tournament.AlreadyCommitted.selector);
        tournament.commit(taskId, _commitment(Bytecode.padded(), bytes32("z"), AGENT_ALICE));
    }

    function test_CannotRevealTwice() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.tight(), bytes32("a"));
        vm.prank(ALICE);
        vm.expectRevert(Tournament.AlreadyRevealed.selector);
        tournament.reveal(taskId, Bytecode.tight(), bytes32("a"));
    }

    // -----------------------------------------------------------------------------------
    // Windows
    // -----------------------------------------------------------------------------------

    function test_CannotCommitAfterCommitEnd() public {
        _enroll(ALICE, AGENT_ALICE);
        vm.warp(commitEnd);
        vm.prank(ALICE);
        vm.expectRevert(Tournament.CommitClosed.selector);
        tournament.commit(taskId, _commitment(Bytecode.tight(), bytes32("a"), AGENT_ALICE));
    }

    function test_CannotRevealBeforeCommitCloses() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        vm.prank(ALICE);
        vm.expectRevert(Tournament.NotInRevealWindow.selector);
        tournament.reveal(taskId, Bytecode.tight(), bytes32("a"));
    }

    function test_CannotRevealAfterRevealEnd() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        vm.warp(revealEnd);
        vm.prank(ALICE);
        vm.expectRevert(Tournament.NotInRevealWindow.selector);
        tournament.reveal(taskId, Bytecode.tight(), bytes32("a"));
    }

    function test_CannotClaimBeforeRevealCloses() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.tight(), bytes32("a"));
        vm.prank(ALICE);
        vm.expectRevert(Tournament.RevealNotClosed.selector);
        tournament.claim(taskId);
    }

    // -----------------------------------------------------------------------------------
    // Nothing strands
    // -----------------------------------------------------------------------------------

    function test_ReclaimWhenNobodyScores() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.wrong(), bytes32("a"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.wrong(), bytes32("a"));

        vm.warp(revealEnd);
        uint256 before = token.balanceOf(CURATOR);
        tournament.reclaim(taskId);
        assertEq(token.balanceOf(CURATOR) - before, POT, "an unwon pot returns in full");
        assertEq(token.balanceOf(address(tournament)), 0, "no tokens stranded");
    }

    function test_PotFullyAccountedAfterClaimsAndReclaim() public {
        _enroll(ALICE, AGENT_ALICE);
        _enroll(BOB, AGENT_BOB);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        _commit(BOB, AGENT_BOB, Bytecode.padded(), bytes32("b"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.tight(), bytes32("a"));
        _reveal(BOB, Bytecode.padded(), bytes32("b"));

        vm.warp(revealEnd);
        vm.prank(ALICE);
        tournament.claim(taskId);
        vm.prank(BOB);
        tournament.claim(taskId);

        // Integer-division dust is the only thing that can be left, and it is reclaimable.
        vm.warp(revealEnd + tournament.CLAIM_WINDOW());
        tournament.reclaim(taskId);
        assertEq(token.balanceOf(address(tournament)), 0, "no tokens stranded after settlement");
    }

    function test_ReclaimBlockedWhileClaimWindowOpen() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.tight(), bytes32("a"));
        vm.warp(revealEnd);
        vm.expectRevert(Tournament.ClaimWindowOpen.selector);
        tournament.reclaim(taskId);
    }
}
