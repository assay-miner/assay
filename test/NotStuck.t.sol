// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";

/// @notice The two ways value used to get stuck, and the guard that keeps the fix honest.
///
/// @dev A five-minute cadence means most windows draw nobody. Before this, a quiet window cost
///      the project the whole window's tax permanently: `collect` needs a score, and every
///      curator path only converted *into* a task. The money was reachable by Flap's Guardian
///      and by no one else.
///
///      Both new paths only move what nobody has earned. That is the property worth testing, not
///      that they move anything at all — a reclaim that could race a miner's share would be a
///      worse bug than the one it fixes.
contract NotStuckTest is BaseTest {
    address internal constant BTCB = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8;
    address internal constant TAXPAYER = address(0x7A);

    AssayFlapVault internal flap;
    address internal guardian;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        flap = new AssayFlapVault(tournament, address(token), CURATOR, new PriceGuard());
        guardian = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    }

    /// @dev Sizes a conversion to what the pool can actually take. Written this way rather than
    ///      with a literal because the testnet BTCB pair is shallow enough that one whole coin
    ///      moves it 1,543 bps — a hardcoded amount passes on one chain and is refused on the
    ///      other, and the number that decides it is the pool's, not ours.
    function _within(uint256 wanted) internal view returns (uint256) {
        uint256 cap = flap.maxConvertible();
        return wanted > cap ? cap : wanted;
    }

    function _tax(uint256 amount) internal {
        vm.deal(TAXPAYER, amount);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: amount}("");
        require(ok, "tax transfer failed");
    }

    function _endow(uint256 bnb) internal returns (uint256) {
        uint256 floor_ = (flap.quote(bnb) * 99) / 100;
        vm.prank(guardian);
        flap.endow(bnb, floor_);
        return flap.fundTaskFromPool(drawnTaskId);
    }

    function _endowTask(uint256 id, uint256 bnb) internal returns (uint256) {
        // The quote is read before the prank: a view call in an argument list consumes it.
        uint256 floor_ = (flap.quote(bnb) * 99) / 100;
        vm.prank(guardian);
        flap.endow(bnb, floor_);
        return flap.fundTaskFromPool(id);
    }

    function _scoringMiner(address miner, uint256 agentId) internal {
        _enroll(miner, agentId);
        _commitDrawn(miner, agentId, drawnTight, bytes32(agentId));
        vm.warp(drawnCommitEnd + 1);
        _revealDrawn(miner, drawnTight, bytes32(agentId));
        vm.warp(drawnRevealEnd + 1);
    }

    // ------------------------------------------------ a window nobody mined

    /// @notice Tax that was never put behind a task comes back, instead of sitting here forever.
    function test_TaxFromAnEmptyWindowGoesToTheProject() public {
        _tax(0.05 ether);
        uint256 before = CURATOR.balance;

        // The window has to be over. Withdrawing mid-task was the discretion a reviewer objected
        // to, and it is gone: while a task is open this reverts for everybody.
        vm.warp(revealEnd);
        vm.prank(CURATOR);
        uint256 sent = flap.withdrawUnconverted(0);

        assertEq(sent, 0.05 ether, "the whole window did not come back");
        assertEq(CURATOR.balance, before + 0.05 ether, "it did not arrive");
        assertEq(flap.freeTax(), 0, "something was left behind");
    }

    /// @notice The cadence the protocol actually runs at: a two-minute epoch, one minute to
    ///         commit and one to reveal. An epoch nobody entered must settle to the project the
    ///         moment reveal closes — not a claim window later, or the tax from an idle market
    ///         would pile up unreachable for thirty days at a time.
    /// @dev An epoch nobody entered settles the moment its window closes, rather than waiting out
    ///      the 30-day claim window that exists for epochs somebody won. Run on the drawn task,
    ///      because that is the lane the reward pool funds — the span is the generator's constants
    ///      now rather than a number this test picks, so it asserts the span it actually got.
    function test_AnEmptyEpochSettlesImmediately() public {
        _tax(0.05 ether);
        uint256 pot = _endow(_within(0.05 ether));
        assertGt(pot, 0, "the drawn task holds nothing to settle");

        // One second before the epoch is over, the money is still the miners'.
        vm.warp(uint256(drawnRevealEnd) - 1);
        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Not settled yet / 尚未结算"));
        flap.reclaimBounty(drawnTaskId);

        // At its end, with nothing revealed, it is the project's — no claim window to wait out.
        vm.warp(drawnRevealEnd);
        vm.prank(ALICE);
        uint256 got = flap.reclaimBounty(drawnTaskId);
        assertEq(got, pot, "the whole bounty did not come back");
        assertEq(flap.rewardPool(), pot, "and it did not land back in the pool");
    }

    /// @notice A window nobody entered is the project's; a bounty somebody won and abandoned is
    ///         not, and is not written off either — it funds the next task.
    /// @dev Two situations that both look like "nobody holds this" and are not the same thing.
    ///      A reviewer asked for unclaimed rewards to roll over rather than reach the curator; the
    ///      owner's rule is that an empty window belongs to the project. Both hold, because the
    ///      two cases are told apart by whether anybody scored at all.
    function test_AnAbandonedBountyRollsOverInsteadOfReachingTheCurator() public {
        _tax(0.05 ether);
        uint256 pot = _endow(_within(0.05 ether));

        // ALICE scores and then never comes back for it.
        _enroll(ALICE, AGENT_ALICE);
        _commitDrawn(ALICE, AGENT_ALICE, drawnTight, bytes32(AGENT_ALICE));
        vm.warp(drawnCommitEnd);
        _revealDrawn(ALICE, drawnTight, bytes32(AGENT_ALICE));
        vm.warp(uint256(drawnRevealEnd) + tournament.CLAIM_WINDOW());

        uint256 curatorBefore = IERC20(BTCB).balanceOf(CURATOR);
        uint256 vaultBefore = IERC20(BTCB).balanceOf(address(flap));

        vm.prank(CURATOR);
        uint256 moved = flap.reclaimBounty(drawnTaskId);

        assertEq(moved, pot, "the whole remainder did not move");
        assertEq(IERC20(BTCB).balanceOf(CURATOR), curatorBefore, "it reached the curator");
        assertEq(IERC20(BTCB).balanceOf(address(flap)), vaultBefore, "it left the vault");
        assertEq(flap.rewardPool(), pot, "it did not roll over");
        assertTrue(flap.solvent(), "the ledger no longer covers what it claims");
    }

    /// And the next task funded picks it up, with nobody choosing to.
    function test_TheNextFundedTaskAbsorbsTheRollover() public {
        _tax(0.05 ether);
        uint256 first = _endow(_within(0.02 ether));

        _enroll(ALICE, AGENT_ALICE);
        _commitDrawn(ALICE, AGENT_ALICE, drawnTight, bytes32(AGENT_ALICE));
        vm.warp(drawnCommitEnd);
        _revealDrawn(ALICE, drawnTight, bytes32(AGENT_ALICE));
        vm.warp(uint256(drawnRevealEnd) + tournament.CLAIM_WINDOW());
        vm.prank(CURATOR);
        flap.reclaimBounty(drawnTaskId);
        assertEq(flap.rewardPool(), first, "nothing rolled over to carry");

        // The rollover lands on the NEXT drawn task, not on a curated one — that is the lane the
        // pool pays. Drawing again is what an operator would do to open the next epoch.
        vm.warp(uint256(tournament.latestRevealEnd()) + 1);
        _postDrawnFixture();
        uint256 next = drawnTaskId;
        uint256 fresh = _endowTask(next, _within(0.01 ether));

        // Both the rollover and the fresh conversion sit in the same pool, and a task takes the
        // whole pool — so `fresh` above already includes what rolled over.
        assertEq(flap.rewardPool(), 0, "the pool was not emptied into the task");
        assertEq(flap.bounty(next), fresh, "the new task did not take the whole pool");
        assertGe(fresh, first, "the rollover was not part of what the task received");
        assertTrue(flap.solvent());
    }

    /// @notice And it cannot touch what is already behind a task.
    function test_WithdrawingCannotReachAnEndowedBounty() public {
        _tax(0.10 ether);
        uint256 pot = _endow(_within(0.05 ether));

        // A finished window is the precondition now, not a permission — see
        // test_NobodyMayWithdrawWhileTheEpochIsOpen.
        // The withdrawal waits on `latestCuratedRevealEnd`, which a drawn post also advances — and
        // the curated fixture task runs longer than the drawn one, so warping to the drawn task's
        // reveal is not enough. Warp past whichever is later rather than naming one.
        vm.warp(uint256(tournament.latestCuratedRevealEnd()) + 1);
        vm.prank(CURATOR);
        flap.withdrawUnconverted(0);

        assertEq(flap.bounty(drawnTaskId), pot, "the bounty moved");
        assertEq(flap.endowed(), pot, "the ledger moved");
        assertTrue(flap.solvent(), "vault is short");
        assertEq(IERC20(BTCB).balanceOf(address(flap)), pot, "BTCB left the vault");
    }

    /// @notice Anybody may settle a finished window, and it can only ever pay the project.
    /// @dev The caller check is gone on purpose. Who receives the money was never the question —
    ///      the destination is fixed at construction — but who chose the moment was, so the
    ///      condition is now the epoch's rather than a permission. A stranger calling this cannot
    ///      redirect a wei of it; all they can do is pay the gas to close a window on time.
    function test_AnyoneMaySettleAFinishedWindowAndItPaysTheProject() public {
        _tax(0.05 ether);
        vm.warp(revealEnd);
        uint256 before = CURATOR.balance;
        uint256 strangerBefore = ALICE.balance;

        vm.prank(ALICE);
        uint256 sent = flap.withdrawUnconverted(0);

        assertEq(sent, 0.05 ether, "the window did not settle in full");
        assertEq(CURATOR.balance, before + 0.05 ether, "the project did not receive it");
        assertEq(ALICE.balance, strangerBefore, "the caller took some of it");
    }

    /// @notice And nobody may take it while the epoch is still running — curator and Guardian
    ///         included. That is the difference between a permission and a condition.
    function test_NobodyMayWithdrawWhileTheEpochIsOpen() public {
        _tax(0.05 ether);
        vm.warp(revealEnd - 1);

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Epoch open / 本期未结束"));
        flap.withdrawUnconverted(0);

        vm.prank(guardian);
        vm.expectRevert(bytes(unicode"Epoch open / 本期未结束"));
        flap.withdrawUnconverted(0);

        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Epoch open / 本期未结束"));
        flap.withdrawUnconverted(0);
    }

    function test_WithdrawingNothingIsAnError() public {
        vm.warp(revealEnd);
        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"No unconverted tax / 无未兑换的税"));
        flap.withdrawUnconverted(0);
    }

    // ------------------------------------------------ a task nobody entered

    /// @notice A bounty on a task that drew no submissions returns to the pool once reveal closes.
    /// @dev It used to reach the curator. Review pushed back twice and the second push was right:
    ///      once the project no longer chooses which task is funded or how much, "the project's
    ///      share" has nothing left to mean. The money the tournament raised stays in the
    ///      tournament, and the project earns it back the same way anybody does — by mining.
    function test_AnUnwonBountyReturnsToThePool() public {
        _tax(0.05 ether);
        uint256 pot = _endow(_within(0.05 ether));

        vm.warp(drawnRevealEnd + 1);
        uint256 curatorBefore = IERC20(BTCB).balanceOf(CURATOR);
        uint256 vaultBefore = IERC20(BTCB).balanceOf(address(flap));

        // No permission: there is no destination left to protect.
        vm.prank(ALICE);
        uint256 got = flap.reclaimBounty(drawnTaskId);

        assertEq(got, pot, "not all of it moved");
        assertEq(flap.rewardPool(), pot, "it did not return to the pool");
        assertEq(IERC20(BTCB).balanceOf(CURATOR), curatorBefore, "it reached the curator");
        assertEq(IERC20(BTCB).balanceOf(address(flap)), vaultBefore, "it left the vault");
        assertTrue(flap.solvent());
    }

    /// @notice Not before the window closes — a miner may still be about to reveal.
    function test_ABountyCannotBeReclaimedEarly() public {
        _tax(0.05 ether);
        _endow(_within(0.05 ether));

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Not settled yet / 尚未结算"));
        flap.reclaimBounty(drawnTaskId);
    }

    /// @notice And never out from under a miner who earned a share.
    ///
    /// @dev This is the test that matters. A reclaim that could race a scoring miner would be a
    ///      worse defect than the lock-up it was written to fix, so the tournament's own claim
    ///      window gates it: while a score exists and the window is open, the curator waits.
    function test_AScoringMinerCannotBeRacedByTheCurator() public {
        _tax(0.05 ether);
        uint256 pot = _endow(_within(0.05 ether));
        _scoringMiner(ALICE, AGENT_ALICE);

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Miners can still collect / 矿工仍可领取"));
        flap.reclaimBounty(drawnTaskId);

        // The miner takes their share on their own schedule.
        vm.prank(ALICE);
        assertEq(flap.collect(drawnTaskId), pot, "the sole scorer did not get the pot");
    }

    /// @notice Once the tournament's claim window has passed, the remainder is reclaimable.
    /// @dev This used to assert the remainder reached the curator. It does not any more, and the
    ///      distinction is the point: somebody scored here, so the money was earned and merely not
    ///      collected. It stays in the protocol and funds a later task. `endowed` therefore does
    ///      not fall — the BTCB never left the vault.
    function test_TheRemainderRollsOverAfterTheClaimWindow() public {
        _tax(0.05 ether);
        uint256 pot = _endow(_within(0.05 ether));
        _scoringMiner(ALICE, AGENT_ALICE);

        vm.warp(drawnRevealEnd + tournament.CLAIM_WINDOW() + 1);
        uint256 curatorBefore = IERC20(BTCB).balanceOf(CURATOR);
        vm.prank(CURATOR);
        uint256 got = flap.reclaimBounty(drawnTaskId);

        assertEq(got, pot, "the unclaimed remainder did not move");
        assertEq(flap.rewardPool(), pot, "it did not roll over");
        assertEq(IERC20(BTCB).balanceOf(CURATOR), curatorBefore, "it reached the curator");
        assertEq(flap.endowed(), pot, "the BTCB left the ledger without leaving the vault");

        // And the miner who slept through the window can no longer take it twice.
        vm.prank(ALICE);
        vm.expectRevert();
        flap.collect(drawnTaskId);
    }

    function test_ABountyCannotBeReclaimedTwice() public {
        _tax(0.05 ether);
        _endow(_within(0.05 ether));
        vm.warp(drawnRevealEnd + 1);

        vm.prank(CURATOR);
        flap.reclaimBounty(drawnTaskId);

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Nothing left / 已无剩余"));
        flap.reclaimBounty(drawnTaskId);
    }

    /// @notice Reclaiming needs no permission, because it moves nothing anybody could redirect.
    function test_AnyoneMayReclaim() public {
        _tax(0.05 ether);
        uint256 pot = _endow(_within(0.05 ether));
        vm.warp(drawnRevealEnd + 1);

        vm.prank(address(0x571A));
        assertEq(flap.reclaimBounty(drawnTaskId), pot, "a stranger could not settle a finished task");
        assertEq(flap.rewardPool(), pot, "it went somewhere other than the pool");
    }
}
