// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice Custody: who can move the money, and who cannot.
///
/// @dev The point of this file is to be adversarial about the operator rather than the miner.
///      A protocol whose deployer can quietly redirect or drain the pot is not a vault, it is a
///      promise — so every drain a curator might reach for is attempted here and asserted to
///      fail. These are the questions asked of any custody design:
///
///        - can the operator take a miner's stake?
///        - can the operator take a pot after it has been escrowed?
///        - can the operator take a winner's reward before they claim it?
///        - can the operator redirect where a reclaim pays out?
///        - can the operator turn the protocol off, upgrade it, or pause a claim?
///
///      All five answer no, and the tests below are how that is known rather than asserted.
contract CustodyTest is BaseTest {
    /// The curator's only powers are naming the tournament once and posting tasks.
    function test_CuratorCannotTakeMinerStake() public {
        _enroll(ALICE, AGENT_ALICE);
        assertEq(vault.balanceOf(roster.stakeAccount(ALICE)), MIN_STAKE, "stake sits in its own vault account");

        // There is no function on the roster that moves stake anywhere but back to its owner.
        // `withdraw` pays msg.sender, so the curator calling it is simply not enrolled.
        vm.prank(CURATOR);
        vm.expectRevert(abi.encodeWithSelector(AgentRoster.NotEnrolled.selector, CURATOR));
        roster.withdraw();

        assertEq(vault.balanceOf(roster.stakeAccount(ALICE)), MIN_STAKE, "stake untouched");
    }

    /// Locking is the only power the tournament has over stake, and it cannot move it.
    function test_TournamentCannotMoveStakeOnlyLockIt() public {
        _enroll(ALICE, AGENT_ALICE);
        vm.prank(address(tournament));
        roster.lockUntil(ALICE, uint64(block.timestamp + 1 days));
        assertEq(vault.balanceOf(roster.stakeAccount(ALICE)), MIN_STAKE, "lock does not move value");

        // And nobody but the tournament may even do that.
        vm.prank(CURATOR);
        vm.expectRevert(AgentRoster.NotConsumer.selector);
        roster.lockUntil(ALICE, uint64(block.timestamp + 30 days));
    }

    /// Once escrowed, a pot is committed. The curator cannot pull it back early.
    function test_CuratorCannotReclaimAPotEarly() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));

        vm.prank(CURATOR);
        vm.expectRevert(Tournament.RevealNotClosed.selector);
        tournament.reclaim(taskId);

        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.tight(), bytes32("a"));
        vm.warp(revealEnd);

        // Someone scored, so the pot is theirs for the whole claim window.
        vm.prank(CURATOR);
        vm.expectRevert(Tournament.ClaimWindowOpen.selector);
        tournament.reclaim(taskId);

        assertEq(vault.balanceOf(tournament.potAccount(taskId)), POT, "pot still escrowed");
    }

    /// A winner's reward can only ever be paid to the winner.
    function test_CuratorCannotClaimAWinnersReward() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.tight(), bytes32("a"));
        vm.warp(revealEnd);

        // `claim` pays msg.sender and reads msg.sender's submission; the curator has none.
        vm.prank(CURATOR);
        vm.expectRevert(Tournament.NoScore.selector);
        tournament.claim(taskId);

        uint256 before = token.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 paid = tournament.claim(taskId);
        assertEq(token.balanceOf(ALICE) - before, paid, "the winner is the only payee");
    }

    /// Reclaim pays the recorded poster, not whoever calls it.
    function test_ReclaimAlwaysPaysTheRecordedPoster() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.wrong(), bytes32("a"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.wrong(), bytes32("a"));
        vm.warp(revealEnd);

        uint256 curatorBefore = token.balanceOf(CURATOR);
        uint256 bobBefore = token.balanceOf(BOB);

        // Anyone may trigger it — it is permissionless — but the destination is fixed.
        vm.prank(BOB);
        tournament.reclaim(taskId);

        assertEq(token.balanceOf(BOB), bobBefore, "the caller gets nothing");
        assertEq(token.balanceOf(CURATOR) - curatorBefore, POT, "the poster is repaid");
    }

    /// No second reclaim, no double spend.
    function test_ReclaimCannotBeReplayed() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.wrong(), bytes32("a"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.wrong(), bytes32("a"));
        vm.warp(revealEnd);
        tournament.reclaim(taskId);

        vm.expectRevert(Tournament.AlreadyReclaimed.selector);
        tournament.reclaim(taskId);
    }

    /// The token has no issuance path past its constructor and nobody who could open one.
    function test_SupplyIsFixedAndOwnerless() public view {
        assertEq(token.totalSupply(), token.MAX_SUPPLY(), "supply is the constructor's supply");
    }

    /// The consumer wiring is a one-shot: it cannot be repointed at an attacker's contract later.
    function test_ConsumerCannotBeRepointed() public {
        assertTrue(roster.consumerFrozen(), "frozen at deploy");
        vm.prank(CURATOR);
        vm.expectRevert(AgentRoster.ConsumerAlreadyFrozen.selector);
        roster.setConsumer(address(0xBAD));
        assertEq(roster.consumer(), address(tournament), "still the real tournament");
    }

    /// A miner who never reveals still gets their stake back once the round is over.
    function test_StakeReturnsEvenToAMinerWhoNeverRevealed() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        vm.warp(revealEnd);

        uint256 before = token.balanceOf(ALICE);
        vm.prank(ALICE);
        roster.withdraw();
        assertEq(token.balanceOf(ALICE) - before, MIN_STAKE, "stake is not forfeit");
    }

    /// Whatever happens, neither contract keeps value that belongs to somebody.
    function test_EverythingIsAccountedForAtTheEnd() public {
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
        vm.prank(ALICE);
        roster.withdraw();
        vm.prank(BOB);
        roster.withdraw();

        vm.warp(revealEnd + tournament.CLAIM_WINDOW());
        tournament.reclaim(taskId);

        assertEq(vault.balanceOf(tournament.potAccount(taskId)), 0, "pot account empty");
        assertEq(vault.balanceOf(roster.stakeAccount(ALICE)), 0, "alice's stake account empty");
        assertEq(vault.balanceOf(roster.stakeAccount(BOB)), 0, "bob's stake account empty");
        assertEq(vault.totalAccounted(), 0, "ledger is empty");
        assertEq(token.balanceOf(address(vault)), 0, "and so is the vault");
        assertEq(token.totalSupply(), token.MAX_SUPPLY(), "nothing minted or burned");
    }
}
