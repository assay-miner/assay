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

    // ------------------------------------------------ an identity that changed hands

    /// @dev Selling the identity used to lock the buyer out for as long as the seller declined to
    ///      withdraw. `minerOf[agentId]` was cleared in one place — `withdraw`, by the bound miner —
    ///      so the only key that could release the binding was the one that had just sold it.
    function test_ABuyerCanEnrolAnIdentityTheSellerNeverUnbound() public {
        vm.startPrank(ALICE);
        token.approve(address(vault), type(uint256).max);
        roster.enroll(AGENT_ALICE, MIN_STAKE);
        vm.stopPrank();
        assertEq(roster.minerOf(AGENT_ALICE), ALICE, "the seller is bound");

        // The identity changes hands. ALICE does not withdraw — nothing makes her.
        registry.mint(AGENT_ALICE, BOB);
        assertEq(roster.minerOf(AGENT_ALICE), ALICE, "the stale binding is still the seller's");

        vm.startPrank(BOB);
        token.approve(address(vault), type(uint256).max);
        roster.enroll(AGENT_ALICE, MIN_STAKE);
        vm.stopPrank();

        assertEq(roster.minerOf(AGENT_ALICE), BOB, "the buyer did not get the binding");
        assertEq(roster.enrolmentOf(BOB).agentId, AGENT_ALICE, "the buyer is not enrolled");
    }

    /// @dev And the seller's stake is still theirs. The takeover deliberately leaves their enrolment
    ///      alone — deleting it would strand what they put in — so `withdraw` still pays them.
    function test_TheSellerCanStillWithdrawAfterLosingTheBinding() public {
        vm.startPrank(ALICE);
        token.approve(address(vault), type(uint256).max);
        roster.enroll(AGENT_ALICE, MIN_STAKE);
        vm.stopPrank();

        registry.mint(AGENT_ALICE, BOB);
        vm.startPrank(BOB);
        token.approve(address(vault), type(uint256).max);
        roster.enroll(AGENT_ALICE, MIN_STAKE);
        vm.stopPrank();

        uint256 before = token.balanceOf(ALICE);
        vm.prank(ALICE);
        roster.withdraw();
        assertEq(token.balanceOf(ALICE) - before, MIN_STAKE, "the seller lost their stake");

        // And that withdrawal must NOT have taken the buyer's binding with it, which an
        // unconditional `delete minerOf[e.agentId]` would have done — leaving the buyer enrolled
        // with nothing bound and looking as though they had never enrolled at all.
        assertEq(roster.minerOf(AGENT_ALICE), BOB, "the seller's withdrawal took the buyer's binding");
    }

    /// @dev The other side of the rule: a holder who still holds the identity keeps the binding.
    ///      Without this the release would be a way to take a live binding rather than a stale one.
    function test_ALiveBindingCannotBeTaken() public {
        vm.startPrank(ALICE);
        token.approve(address(vault), type(uint256).max);
        roster.enroll(AGENT_ALICE, MIN_STAKE);
        vm.stopPrank();

        // CAROL is authorised for her own identity, not for ALICE's, and ALICE still holds hers.
        vm.startPrank(CAROL);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes(unicode"Agent already bound / agent 已被绑定"));
        roster.enroll(AGENT_ALICE, MIN_STAKE);
        vm.stopPrank();

        assertEq(roster.minerOf(AGENT_ALICE), ALICE, "a live binding was taken");
    }

    /// @dev The replay the released holder could otherwise run, and the line that stops it.
    ///
    ///      Releasing a stale binding leaves the old holder's enrolment in place on purpose — their
    ///      stake is in it. That made one identity able to back two live enrolments, and
    ///      `Tournament.commit` places no uniqueness constraint on `commitment` across miners while
    ///      `submissions` is public. So the released holder could copy the new holder's commitment
    ///      verbatim, wait for them to reveal, and replay the same `(runtime, salt)` — which
    ///      verifies, because `reveal` hashes against `s.agentId` and both carried the same one.
    ///
    ///      Measured before the guard: one leg took 50.0% of the pot for no work, three took 75.0%.
    ///
    ///      This does not need a sale. `AgentRoster`'s own header documents the delegation this
    ///      enables — the NFT can stay in cold storage while a disposable hot key does the mining —
    ///      and every rotation of that key is
    ///      exactly the release condition — so a rotated-out key kept a replay channel against its
    ///      own owner's new one.
    function test_AReleasedHolderCannotCommitAgain() public {
        address hot1 = makeAddr("hot1");
        address hot2 = makeAddr("hot2");
        vm.startPrank(CURATOR);
        token.transfer(hot1, MIN_STAKE * 2);
        token.transfer(hot2, MIN_STAKE * 2);
        vm.stopPrank();

        registry.authorize(AGENT_ALICE, hot1, true);
        vm.startPrank(hot1);
        token.approve(address(vault), type(uint256).max);
        roster.enroll(AGENT_ALICE, MIN_STAKE);
        vm.stopPrank();

        // The owner rotates the hot key, exactly as the header recommends.
        registry.authorize(AGENT_ALICE, hot1, false);
        registry.authorize(AGENT_ALICE, hot2, true);

        vm.startPrank(hot2);
        token.approve(address(vault), type(uint256).max);
        roster.enroll(AGENT_ALICE, MIN_STAKE);
        vm.stopPrank();
        assertEq(roster.minerOf(AGENT_ALICE), hot2, "the new key did not take the binding");

        // hot1's enrolment survives — that is deliberate, the stake is in it — but it no longer
        // carries the right to mine, which is what closes the replay.
        assertEq(roster.enrolmentOf(hot1).agentId, AGENT_ALICE, "the old key's enrolment was deleted");
        vm.prank(hot1);
        vm.expectRevert(bytes(unicode"Binding was released / 绑定已被释放"));
        tournament.commit(taskId, keccak256("anything"));

        // And the stake is still hot1's to take back.
        uint256 before = token.balanceOf(hot1);
        vm.prank(hot1);
        roster.withdraw();
        assertEq(token.balanceOf(hot1) - before, MIN_STAKE, "the released key lost its stake");
    }

    /// @dev A registry that cannot answer must not release anything. The query runs before the
    ///      "already bound" refusal, so a registry reverting on demand would otherwise have been a
    ///      way to release every binding — an unanswerable query is not an answer that the holder
    ///      lost the identity.
    function test_AnUnanswerableRegistryReleasesNothing() public {
        vm.startPrank(ALICE);
        token.approve(address(vault), type(uint256).max);
        roster.enroll(AGENT_ALICE, MIN_STAKE);
        vm.stopPrank();

        vm.mockCallRevert(
            address(registry),
            abi.encodeWithSelector(registry.isAuthorizedOrOwner.selector, ALICE, AGENT_ALICE),
            bytes("ERC721: invalid token ID")
        );

        registry.authorize(AGENT_ALICE, CAROL, true);
        vm.startPrank(CAROL);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes(unicode"Agent already bound / agent 已被绑定"));
        roster.enroll(AGENT_ALICE, MIN_STAKE);
        vm.stopPrank();

        assertEq(roster.minerOf(AGENT_ALICE), ALICE, "an unanswerable registry released a binding");
    }
}
