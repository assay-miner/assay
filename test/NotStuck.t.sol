// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Stack} from "../script/Stack.sol" ;
import {Guardians} from "./Guardians.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";

/// @notice The two ways value used to get stuck, and the guard that keeps the fix honest.
///
/// @dev A five-minute cadence means most windows draw nobody. Before this, a quiet window's tax
///      was stranded permanently: `collect` needs a score, and every conversion path only
///      converted *into* a task. The money was reachable by Flap's Guardian and by no one else.
///
///      What unstuck it was never a way out of the vault. Idle tax converts into `rewardPool`,
///      the pool funds the next drawn task, and a bounty nobody claimed rolls back into the pool
///      — so the money moves on without leaving. The withdrawal that used to pay a curator was
///      removed at the reviewer's request, and the tests below assert what its absence leaves
///      true: the value stays here, and the only ways out are a scored miner's `collect` and
///      Flap's Guardian.
///
///      Both rollover paths only move what nobody has earned. That is the property worth testing,
///      not that they move anything at all — a reclaim that could race a miner's share would be a
///      worse bug than the one it fixes.
contract NotStuckTest is BaseTest {
    address internal constant BTCB = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8;
    address internal constant TRIGGER = 0x560E9830926C9e0EB98a59c6b9902383Fc0D9Eb2;
    address internal constant TAXPAYER = address(0x7A);

    AssayFlapVault internal flap;
    address internal guardian;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        flap = Stack.newFlapVault(Guardians.TESTNET, tournament, address(token), Stack.newPriceGuard(Guardians.TESTNET));
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

    /// @notice Tax that was never put behind a task waits here for the next one, instead of
    ///         leaving to an address.
    /// @dev This asserted that a finished window paid its whole balance out to the curator. That
    ///      path is gone, and with it the last route from this vault to anybody but a scored miner
    ///      or Flap's Guardian. So an empty window produces tax still sitting in `freeTax()` — not
    ///      stranded, which is what this file is about, but not anybody's either: the next
    ///      conversion picks it up and the next drawn task takes it.
    function test_TaxFromAnEmptyWindowWaitsForTheNextTask() public {
        _tax(0.05 ether);
        uint256 before = CURATOR.balance;

        // The window ends with nobody having mined it, and nothing happens to the money at all.
        vm.warp(revealEnd);
        assertEq(flap.freeTax(), 0.05 ether, "the window's tax did not stay in the vault");
        assertEq(CURATOR.balance, before, "the tax reached the curator");

        // And the next epoch's drawn task takes it, as BTCB, with nobody choosing to.
        vm.warp(uint256(tournament.latestRevealEnd()) + 1);
        _postDrawnFixture();
        uint256 funded = _endowTask(drawnTaskId, _within(0.05 ether));
        assertGt(funded, 0, "the waiting tax never reached a task");
        assertEq(flap.bounty(drawnTaskId), funded, "and it is not on the bounty");
        assertTrue(flap.solvent(), "the ledger no longer covers what it claims");
    }

    /// @notice The cadence the protocol actually runs at: a twenty-minute epoch, ten minutes to
    ///         commit and ten to reveal, both constants on `TaskGenerator`. An epoch nobody entered
    ///         must settle back into the pool the moment reveal closes — not a claim window later,
    ///         or the tax from an idle market would sit behind dead tasks for thirty days at a time.
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

        // At its end, with nothing revealed, it goes back to the pool — no claim window to wait out.
        vm.warp(drawnRevealEnd);
        vm.prank(ALICE);
        uint256 got = flap.reclaimBounty(drawnTaskId);
        assertEq(got, pot, "the whole bounty did not come back");
        assertEq(flap.rewardPool(), pot, "and it did not land back in the pool");
    }

    /// @notice A bounty somebody won and abandoned is not written off, and does not leave — it
    ///         funds the next task.
    /// @dev Two situations that both look like "nobody holds this", and what tells them apart is
    ///      whether anybody scored at all. They no longer differ in destination — both land back
    ///      in `rewardPool` — only in how long the vault waits before saying so: immediately for a
    ///      window nobody entered, and a full claim window for one somebody won.
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

    /// @notice And nothing that moves the native balance can touch what is already behind a task.
    /// @dev Asserted of `withdrawUnconverted` until that function was removed: it paid idle BNB
    ///      out and had to be shown not to reach converted BTCB. The remaining native path is the
    ///      Guardian's Rule 009 hatch, and it is held to the same line — it empties the BNB and
    ///      leaves every bounty, the ledger and `solvent()` exactly as they were, because a bounty
    ///      is BTCB and this hatch does not move tokens. The token hatch deliberately can, which is
    ///      what Rule 009 asks for and what `solvent()` exists to make visible.
    function test_TheNativeHatchCannotReachAnEndowedBounty() public {
        _tax(0.10 ether);
        uint256 pot = _endow(_within(0.05 ether));

        address rescue = makeAddr("rescue");
        vm.prank(guardian);
        flap.emergencyWithdrawNative(rescue);

        assertGt(rescue.balance, 0, "the hatch moved no native at all, so this asserts nothing");
        assertEq(flap.bounty(drawnTaskId), pot, "the bounty moved");
        assertEq(flap.endowed(), pot, "the ledger moved");
        assertTrue(flap.solvent(), "vault is short");
        assertEq(IERC20(BTCB).balanceOf(address(flap)), pot, "BTCB left the vault");
    }

    /// @notice Anybody may set a finished window's tax moving, and it can only ever move toward
    ///         miners.
    /// @dev The caller check was dropped from the old withdrawal because who received the money
    ///      was never the question — that destination was fixed at construction — and who chose
    ///      the moment was. The withdrawal has since gone the same way, so the permissionless call
    ///      this asserts about is `triggerConversion`: a stranger pays the scheduler's fee, the
    ///      vault sizes and prices the conversion itself, the service executes at a moment nobody
    ///      here picked, and what comes back is BTCB in the pool. There is no destination left for
    ///      a caller to name.
    function test_AnyoneMayStartTheConversionAndKeepsNoneOfIt() public {
        _tax(0.05 ether);
        vm.warp(revealEnd);
        uint256 before = CURATOR.balance;
        uint256 callerBtcb = IERC20(BTCB).balanceOf(ALICE);
        uint256 fee = flap.schedulerFee();
        // Dealt exactly the fee, so any BNB the caller holds afterwards came out of the vault.
        vm.deal(ALICE, fee);

        vm.prank(ALICE);
        uint256 id = flap.triggerConversion{value: fee}();
        assertGt(id, 0, "a stranger could not start the conversion");
        assertEq(address(flap).balance, 0.05 ether, "the window's tax did not stay put");

        vm.prank(TRIGGER);
        flap.trigger(id);

        assertGt(flap.rewardPool(), 0, "the window did not become prize money");
        assertEq(ALICE.balance, 0, "the caller took some of it");
        assertEq(IERC20(BTCB).balanceOf(ALICE), callerBtcb, "the caller took the proceeds");
        assertEq(CURATOR.balance, before, "the tax reached the curator");
    }

    /// @notice And nobody may take it out of the vault at all, in any epoch — curator, stranger
    ///         and Guardian alike. The Guardian's own route is Rule 009's hatch, which is a rescue
    ///         and is asserted here beside the refusals so "not stuck" and "not anybody's" are one
    ///         statement rather than two.
    /// @dev This used to assert that the withdrawal was shut while an epoch ran: a condition
    ///      rather than a permission. The condition became total when the function was removed,
    ///      which is what the reviewer asked for — funds stay in the vault and go on being used
    ///      for what they were raised for, and an emergency goes through Flap's Guardian.
    ///
    ///      By selector, because this file cannot name a function the vault no longer declares,
    ///      and the vault has no `fallback` — so an unimplemented selector reverts for everyone.
    function test_NobodyCanTakeTheTaxOutExceptThroughTheGuardiansHatch() public {
        _tax(0.05 ether);
        vm.warp(revealEnd - 1);

        bytes memory gone = abi.encodeWithSignature("withdrawUnconverted(uint256)", uint256(0));
        address[3] memory callers = [CURATOR, guardian, ALICE];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            (bool ok,) = address(flap).call(gone);
            assertFalse(ok, "the withdrawal is still reachable");
        }
        assertEq(address(flap).balance, 0.05 ether, "something left the vault");

        // Flap's, and nobody else's.
        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Only the guardian / 仅限守护者"));
        flap.emergencyWithdrawNative(ALICE);

        address rescue = makeAddr("rescue");
        vm.prank(guardian);
        flap.emergencyWithdrawNative(rescue);
        assertEq(rescue.balance, 0.05 ether, "the Guardian could not rescue it");
    }

    /// @dev The empty case still fails loudly rather than quietly doing nothing. This asserted it
    ///      of a withdrawal against an empty balance; the call that can now be made against one is
    ///      the conversion, and it refuses to spend a scheduler fee on converting nothing.
    function test_ConvertingNothingIsAnError() public {
        vm.warp(revealEnd);
        uint256 fee = flap.schedulerFee();
        vm.deal(CURATOR, fee);
        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Nothing to convert / 无可兑换"));
        flap.triggerConversion{value: fee}();
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
