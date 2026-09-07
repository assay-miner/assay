// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";

/// @notice What open posting is worth when a griefer wants it for nobody.
///
/// @dev `OPEN_POST_MAX_SPAN` bounds one open post at ten minutes so a single stranger cannot freeze
///      the fallback path for thirty days. It does not bound how many times one stranger posts —
///      only how long each post lasts — and `latestRevealEnd` is a single global lock, so whoever
///      wins the race to post right as it opens keeps winning it, forever, for the cost of gas.
///
///      Two mitigations look obvious and both are tested here to be worthless:
///
///      Requiring a non-zero pot does not raise the cost, because reclaiming it back is nearly
///      free. `reclaim` pays out the moment `revealEnd` passes if nobody scored
///      (`totalScore == 0`, skipping the 30-day `CLAIM_WINDOW`), and nobody will have scored —
///      real miners are not going to spend gas competing for a task the griefer posted only to
///      occupy the slot. So the griefer's capital is locked for the length of the window they
///      chose, which they also control, and comes back whole.
///
///      Rejecting a repeat poster does not survive a second address. Any address-keyed cooldown
///      is a one-line workaround for anyone willing to hold two EOAs, which costs nothing on a
///      chain where accounts are free.
///
///      What is NOT reachable this way: the reward pool. `fundTaskFromPool` pays only
///      `latestGeneratedTaskId`, which is written on the drawn lane and nowhere else, so a griefer's
///      open posts can never be handed the converted tax — and neither can the project's own curated
///      ones. Occupying the slot denies other STRANGERS a chance to post; the funded lane does not
///      read `latestRevealEnd` at all, so it is not blocked by this at all. Acknowledged rather than fixed: every
///      mitigation we found either does not work (above) or requires an off-chain trust
///      assumption this contract does not have (recognising that two addresses are the same
///      actor). Recorded as a test so the mechanism is measured rather than left as a paragraph
///      nobody re-checks.
contract OpenPostMonopolyTest is BaseTest {
    address internal constant GRIEFER = address(0xBAD1);
    address internal constant HONEST_STRANGER = address(0xF00D);

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
    }

    // Warps to just past whatever latestRevealEnd is RIGHT NOW, not a fixed value — the mark
    // keeps moving forward as the griefer posts, and each cycle has to open relative to where it
    // actually stands or the loop is testing a window that already closed behind it.
    function _openWindow() internal {
        vm.warp(uint256(tournament.latestRevealEnd()) + 1);
    }

    /// @dev One stranger, occupying the slot every cycle with a pot of zero, indefinitely denies a
    ///      second stranger who is willing to pay. `OPEN_POST_MAX_SPAN` bounds each individual
    ///      post; nothing bounds how many times the same address may be first back in line.
    function test_AGrieferHoldsTheOpenSlotAgainstAnHonestStranger() public {
        _openWindow();

        deal(address(token), HONEST_STRANGER, 1);
        vm.prank(HONEST_STRANGER);
        token.approve(address(vault), 1);

        for (uint256 round; round < 3; ++round) {
            // The longest span a single post may claim — what a griefer actually posts to hold the
            // slot for as long as possible each cycle.
            uint64 revealEnd_ = uint64(block.timestamp + tournament.OPEN_POST_MAX_SPAN());
            uint64 commitEnd_ = uint64(revealEnd_ - 1);

            vm.prank(GRIEFER);
            tournament.postTask(inputs, expected, Bytecode.verbose(), GAS_CAP, commitEnd_, revealEnd_, 0);

            // The honest stranger, ready to pay real ASSAY for a real task, cannot get in edgewise.
            vm.prank(HONEST_STRANGER);
            vm.expectRevert(bytes(unicode"Not the curator / 非策展方"));
            tournament.postTask(inputs, expected, Bytecode.verbose(), GAS_CAP, commitEnd_, uint64(commitEnd_ + 30), 1);

            _openWindow();
        }

        // Three cycles, and the honest stranger never got a task in — this is "indefinitely", not
        // "eventually", bounded only by how long the griefer keeps paying gas.
    }

    /// @dev The control. Absent the griefer, the same honest stranger posts without incident the
    ///      moment the window opens — confirming the revert above is the griefer's occupation and
    ///      not a mistake in how this test builds its call.
    function test_AnHonestStrangerPostsFineWhenNobodyIsHoldingTheSlot() public {
        _openWindow();

        deal(address(token), HONEST_STRANGER, 1);
        vm.startPrank(HONEST_STRANGER);
        token.approve(address(vault), 1);

        uint64 revealEnd_ = uint64(block.timestamp + tournament.OPEN_POST_MAX_SPAN());
        uint64 commitEnd_ = uint64(revealEnd_ - 1);
        uint256 tid =
            tournament.postTask(inputs, expected, Bytecode.verbose(), GAS_CAP, commitEnd_, revealEnd_, 1);
        vm.stopPrank();

        assertGt(tid, 0, "the honest stranger's post did not land");
    }

    /// @dev The obvious fix — require pot > 0 — does not raise the cost of the attack, because the
    ///      capital comes back. Confirms the reclaim path is actually reachable this fast: no score
    ///      forms (nobody plays a task posted only to occupy the slot), so CLAIM_WINDOW is skipped
    ///      entirely and the pot is recoverable the instant revealEnd passes.
    function test_ANonZeroPotIsNotARealCostBecauseItComesRightBack() public {
        _openWindow();

        uint128 pot = 1_000e18;
        deal(address(token), GRIEFER, pot);
        vm.startPrank(GRIEFER);
        token.approve(address(vault), pot);

        uint64 revealEnd_ = uint64(block.timestamp + tournament.OPEN_POST_MAX_SPAN());
        uint64 commitEnd_ = uint64(revealEnd_ - 1);
        uint256 tid = tournament.postTask(inputs, expected, Bytecode.verbose(), GAS_CAP, commitEnd_, revealEnd_, pot);
        vm.stopPrank();

        uint256 before = token.balanceOf(GRIEFER);
        assertEq(before, 0, "the pot left the griefer's balance");

        vm.warp(uint256(revealEnd_) + 1);

        vm.prank(GRIEFER);
        uint256 back = tournament.reclaim(tid);

        assertEq(back, pot, "the whole pot came back");
        assertEq(token.balanceOf(GRIEFER), pot, "immediately spendable on the next post");
    }
}
