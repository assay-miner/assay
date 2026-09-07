// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";

contract RosterTest is BaseTest {
    function test_EnrolRequiresErc8004Authorisation() public {
        // Alice does not own agent 99 and was never authorised for it.
        vm.startPrank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes(unicode"Not authorised for this agent / 无该 agent 的权限"));
        roster.enroll(99, MIN_STAKE);
        vm.stopPrank();
    }

    /// @dev The delegation path: the identity NFT stays with its owner while a separate hot key
    ///      does the mining. This is why the gate uses `isAuthorizedOrOwner` and not `ownerOf`.
    function test_AuthorisedHotKeyCanEnrolWithoutHoldingTheNft() public {
        address hotKey = address(0xB07);
        registry.authorize(AGENT_ALICE, hotKey, true);

        vm.prank(CURATOR);
        token.transfer(hotKey, MIN_STAKE);

        vm.startPrank(hotKey);
        token.approve(address(vault), type(uint256).max);
        roster.enroll(AGENT_ALICE, MIN_STAKE);
        vm.stopPrank();

        assertEq(roster.minerOf(AGENT_ALICE), hotKey, "hot key is bound");
        assertEq(registry.ownerOf(AGENT_ALICE), ALICE, "nft never moved");
    }

    function test_OneIdentityCannotBackTwoMiners() public {
        _enroll(ALICE, AGENT_ALICE);
        vm.startPrank(BOB);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(
            bytes(unicode"Agent already bound / agent 已被绑定")
        );
        roster.enroll(AGENT_ALICE, MIN_STAKE);
        vm.stopPrank();
    }

    function test_StakeBelowMinimumRejected() public {
        vm.startPrank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(
            bytes(unicode"Stake below minimum / 质押低于下限")
        );
        roster.enroll(AGENT_ALICE, MIN_STAKE - 1);
        vm.stopPrank();
    }

    function test_UnenrolledCannotCommit() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Not enrolled / 未注册"));
        tournament.commit(taskId, _commitment(Bytecode.tight(), bytes32("a"), AGENT_ALICE));
    }

    /// @dev Committing must pin the stake for the round, or the sybil cost is refundable and
    ///      therefore not a cost at all.
    function test_CommitLocksStakeUntilRevealCloses() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));

        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Stake is locked / 质押锁定中"));
        roster.withdraw();

        vm.warp(revealEnd);
        vm.prank(ALICE);
        roster.withdraw();
        assertEq(roster.minerOf(AGENT_ALICE), address(0), "identity released on withdrawal");
    }

    /// @dev Withdrawing must not strand an earned payout.
    function test_WithdrawingStakeDoesNotVoidAPendingClaim() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.tight(), bytes32("a"));

        vm.warp(revealEnd);
        vm.prank(ALICE);
        roster.withdraw();

        vm.prank(ALICE);
        uint256 paid = tournament.claim(taskId);
        assertGt(paid, 0, "claim survives unenrolment");
    }

    function test_OnlyTournamentCanLockStake() public {
        _enroll(ALICE, AGENT_ALICE);
        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Not the consumer / 非消费者"));
        roster.lockUntil(ALICE, uint64(block.timestamp + 1 days));
    }

    function test_ConsumerFrozenAfterFirstSet() public {
        // As the deployer: the freeze is what must stop this, not the caller check in front of it.
        vm.expectRevert(bytes(unicode"Consumer is frozen / 消费者已冻结"));
        roster.setConsumer(address(0xdead));
    }

    function test_OnlyCuratorPostsTasks() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Not the curator / 非策展方"));
        tournament.postTask(inputs, expected, Bytecode.tight(), GAS_CAP, commitEnd, revealEnd, POT);
    }

    // ------------------------------------------------------ the id that would not survive a commit

    /// @dev `Tournament.Submission.agentId` is a `uint64` and `commit` narrows to it, while `reveal`
    ///      recomputes the commitment from that narrowed value and the NatSpec documents the full
    ///      one. So an id above `type(uint64).max` used to enrol cleanly, commit cleanly, and then
    ///      fail `reveal` with "Commitment mismatch" — after `lockUntil` had already pinned the
    ///      stake to the task's reveal. The miner lost an epoch and could not withdraw.
    ///
    ///      Refused at enrolment now, which is the cheapest place: nothing is staked yet.
    function test_AnAgentIdTooLargeForASubmissionIsRefusedAtEnrolment() public {
        uint256 tooBig = uint256(type(uint64).max) + 1;
        registry.mint(tooBig, ALICE);

        vm.startPrank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes(unicode"Agent id too large / agent 编号过大"));
        roster.enroll(tooBig, MIN_STAKE);
        vm.stopPrank();

        // And nothing was taken: the refusal is before any stake moves.
        assertEq(roster.enrolmentOf(ALICE).stake, 0, "a refused enrolment still took a stake");
    }

    /// @dev The boundary itself, from both sides, so the bound is the value it claims to be rather
    ///      than one off it.
    function test_TheLargestIdASubmissionCanHoldStillEnrols() public {
        uint256 largest = uint256(type(uint64).max);
        registry.mint(largest, BOB);

        vm.startPrank(BOB);
        token.approve(address(vault), type(uint256).max);
        roster.enroll(largest, MIN_STAKE);
        vm.stopPrank();

        assertEq(roster.enrolmentOf(BOB).agentId, largest, "the largest fitting id was refused");
    }
}
