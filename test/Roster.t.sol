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
        vm.expectRevert(abi.encodeWithSelector(AgentRoster.NotAuthorizedForAgent.selector, ALICE, 99));
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
            abi.encodeWithSelector(AgentRoster.AgentAlreadyBound.selector, AGENT_ALICE, ALICE)
        );
        roster.enroll(AGENT_ALICE, MIN_STAKE);
        vm.stopPrank();
    }

    function test_StakeBelowMinimumRejected() public {
        vm.startPrank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(AgentRoster.StakeBelowMinimum.selector, MIN_STAKE - 1, MIN_STAKE)
        );
        roster.enroll(AGENT_ALICE, MIN_STAKE - 1);
        vm.stopPrank();
    }

    function test_UnenrolledCannotCommit() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(AgentRoster.NotEnrolled.selector, ALICE));
        tournament.commit(taskId, _commitment(Bytecode.tight(), bytes32("a"), AGENT_ALICE));
    }

    /// @dev Committing must pin the stake for the round, or the sybil cost is refundable and
    ///      therefore not a cost at all.
    function test_CommitLocksStakeUntilRevealCloses() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(AgentRoster.StakeLockedUntil.selector, revealEnd));
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
        vm.expectRevert(AgentRoster.NotConsumer.selector);
        roster.lockUntil(ALICE, uint64(block.timestamp + 1 days));
    }

    function test_ConsumerFrozenAfterFirstSet() public {
        // As the deployer: the freeze is what must stop this, not the caller check in front of it.
        vm.expectRevert(AgentRoster.ConsumerAlreadyFrozen.selector);
        roster.setConsumer(address(0xdead));
    }

    function test_OnlyCuratorPostsTasks() public {
        vm.prank(ALICE);
        vm.expectRevert(Tournament.NotCurator.selector);
        tournament.postTask(inputs, expected, Bytecode.tight(), GAS_CAP, commitEnd, revealEnd, POT);
    }
}
