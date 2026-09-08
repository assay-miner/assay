// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Stack} from "../script/Stack.sol" ;
import {Guardians} from "./Guardians.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";

/// @notice The reward asset, exercised against the real market it depends on.
///
/// @dev Forked rather than mocked. The conversion this vault performs is the one place the
///      protocol touches a price, and a mock router would only ever confirm the arithmetic I
///      already wrote — not that the path exists, that the pair is funded, or that what the
///      router returns is what the vault books. Those are the parts that can be wrong.
///
///      Not skipped when the fork is unavailable: the vault resolves its reward token and
///      router from `block.chainid` in its constructor, so without a fork there is no vault to
///      test, and a suite that passes in that state is reporting on nothing.
contract RewardAssetTest is BaseTest {
    address internal constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address internal constant TAXPAYER = address(0x7A);
    /// @dev Chain 56's Guardian. `endow` is the escape hatch now; the curator schedules instead.
    address internal constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    address internal constant SPONSOR = address(0x5B);

    AssayFlapVault internal flap;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc"));
        super.setUp();
        flap = Stack.newFlapVault(Guardians.TESTNET, tournament, address(token), Stack.newPriceGuard(Guardians.TESTNET));
    }

    /// @dev Tax arrives the way Flap sends it: a plain native transfer.
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

    /// @dev A miner with a real, recorded score.
    /// @dev Mines the DRAWN task, because that is the one the reward pool pays. Mining the curated
    ///      fixture task would score fine and collect nothing — the bounty is not there any more.
    function _scoringMiner(address miner, uint256 agentId) internal {
        _enroll(miner, agentId);
        _commitDrawn(miner, agentId, drawnTight, bytes32(agentId));
        vm.warp(drawnCommitEnd + 1);
        _revealDrawn(miner, drawnTight, bytes32(agentId));
        vm.warp(drawnRevealEnd + 1);
    }

    /// @dev The floor an operator would actually pass: one percent under the pool's own price.
    ///      Zero is no longer accepted, and it should not have been — a privileged caller who
    ///      may declare any price acceptable can sandwich the vault's own conversion.
    function _floor(uint256 bnbAmount) internal view returns (uint256) {
        return (flap.quote(bnbAmount) * 99) / 100;
    }

    // -------------------------------------------------------------------------------------

    function test_TheVaultKnowsWhatItPaysIn() public view {
        assertEq(address(flap.reward()), BTCB, "reward is not BTCB");
        assertEq(IERC20(BTCB).balanceOf(address(flap)), 0, "starts holding none");
        assertTrue(flap.solvent(), "an empty vault is trivially solvent");
    }

    function test_TaxArrivesAsBnbAndIsEntirelyUnassigned() public {
        _tax(3 ether);
        assertEq(flap.freeTax(), 3 ether, "native tax is unassigned by construction");
        assertEq(flap.endowed(), 0, "nothing is behind a task yet");
    }

    /// @notice The whole point: BNB goes in, BTCB comes out, and the bounty is booked in BTCB.
    function test_EndowConvertsToBtcbAndBooksWhatActuallyArrived() public {
        _tax(3 ether);

        uint256 quoted = flap.quote(_within(2 ether));
        assertGt(quoted, 0, "no route from BNB to BTCB");

        uint256 amt1_ = _within(2 ether);
        vm.prank(GUARDIAN);
        uint256 got = flap.endow(amt1_, (quoted * 99) / 100);

        assertEq(IERC20(BTCB).balanceOf(address(flap)), got, "vault holds exactly what it booked");
        assertEq(flap.endowed(), got, "endowed tracks the tokens, not the coins spent");
        // A conversion credits the pool, not a task. Naming a task while converting was where the
        // curator's discretion lived, so the two are separate calls now.
        assertEq(flap.rewardPool(), got, "the pool is the tokens");
        assertEq(flap.bounty(drawnTaskId), 0, "a conversion funded a task by itself");
        flap.fundTaskFromPool(drawnTaskId);
        assertEq(flap.bounty(drawnTaskId), got, "the task did not take the pool");
        assertEq(flap.freeTax(), 1 ether, "the unconverted remainder stays native");
        assertTrue(flap.solvent(), "every open bounty is covered");
        assertApproxEqRel(got, quoted, 0.01e18, "booked far from the quote");
    }

    /// @notice The slippage floor is a floor, not a suggestion.
    function test_EndowRevertsBelowTheFloor() public {
        _tax(2 ether);
        uint256 quoted = flap.quote(_within(1 ether));

        uint256 amt2_ = _within(1 ether);
        vm.prank(GUARDIAN);
        vm.expectRevert();
        flap.endow(amt2_, quoted * 2);

        assertEq(flap.endowed(), 0, "a reverted conversion books nothing");
        assertEq(flap.freeTax(), 2 ether, "and spends nothing");
    }

    function test_OnlyTheGuardianUsesTheEscapeHatch() public {
        _tax(1 ether);
        uint256 floor_ = _floor(_within(1 ether));
        uint256 amt3_ = _within(1 ether);
        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Only the guardian / 仅限守护者"));
        flap.endow(amt3_, floor_);

        // And the curator, who used to hold this, no longer does.
        uint256 amt4_ = _within(1 ether);
        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Only the guardian / 仅限守护者"));
        flap.endow(amt4_, floor_);
    }

    function test_CannotEndowMoreThanHasArrived() public {
        _tax(1 ether);
        uint256 floor_ = _floor(_within(2 ether));
        uint256 amt5_ = _within(2 ether);
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Exceeds unconverted tax / 超过未兑换的税"));
        flap.endow(amt5_, floor_);
    }

    /// @notice A scoring miner is paid in BTCB, and the native balance never moves for them.
    function test_TheMinerIsPaidInBtcb() public {
        _tax(2 ether);
        uint256 floor_ = _floor(_within(2 ether));
        uint256 amt6_ = _within(2 ether);
        vm.prank(GUARDIAN);
        uint256 pot = flap.endow(amt6_, floor_);
        flap.fundTaskFromPool(drawnTaskId);

        _scoringMiner(ALICE, AGENT_ALICE);

        uint256 due = flap.collectable(drawnTaskId, ALICE);
        assertGt(due, 0, "a scoring miner is owed something");

        uint256 bnbBefore = ALICE.balance;
        vm.prank(ALICE);
        uint256 got = flap.collect(drawnTaskId);

        assertEq(got, due, "paid what was owed");
        assertEq(IERC20(BTCB).balanceOf(ALICE), got, "the miner holds BTCB");
        assertEq(ALICE.balance, bnbBefore, "and received no native coin");
        assertEq(flap.endowed(), pot - got, "the open bounty shrinks by what was paid");
        assertEq(flap.totalPaid(), got, "and the paid total grows by it");
        assertEq(flap.payouts(), 1, "one payout recorded");
        assertTrue(flap.solvent(), "still covers what is left open");
    }

    function test_AMinerCannotCollectTwice() public {
        _tax(1 ether);
        uint256 floor_ = _floor(_within(1 ether));
        uint256 amt7_ = _within(1 ether);
        vm.prank(GUARDIAN);
        flap.endow(amt7_, floor_);
        flap.fundTaskFromPool(drawnTaskId);
        _scoringMiner(ALICE, AGENT_ALICE);

        vm.prank(ALICE);
        flap.collect(drawnTaskId);
        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Already collected / 已经领取过了"));
        flap.collect(drawnTaskId);
    }

    /// @notice Anyone may make a bounty larger; nobody may make it smaller.
    function test_AnyoneCanSponsorInBtcb() public {
        uint256 amount = 5e15; // 0.005 BTCB
        deal(BTCB, SPONSOR, amount);

        vm.startPrank(SPONSOR);
        IERC20(BTCB).approve(address(flap), amount);
        flap.sponsor(drawnTaskId, amount);
        vm.stopPrank();

        assertEq(flap.bounty(drawnTaskId), amount, "the sponsorship is the bounty");
        assertEq(flap.endowed(), amount, "and is accounted as open");
        assertTrue(flap.solvent());

        _scoringMiner(ALICE, AGENT_ALICE);
        vm.prank(ALICE);
        assertEq(flap.collect(drawnTaskId), amount, "a lone scorer takes the whole sponsored pot");
    }

    /// @notice Money cannot be put behind a task that does not exist.
    ///
    /// @dev The failure this prevents is silent and total. There is no owner and no sweep here,
    ///      so BTCB booked against a task id nobody will ever score on cannot be recovered by
    ///      anyone, ever — a mistyped digit in an ops script is a permanent loss, and every
    /// @notice Funding a task that does not exist is refused. Converting cannot name one at all.
    /// @dev This checked that `endow` rejected an unknown task. `endow` takes no task now — that
    ///      was the point of splitting conversion from funding — so the check moves to the call
    ///      that does name one.
    function test_CannotFundATaskThatDoesNotExist() public {
        _tax(1 ether);
        uint256 amt = _within(0.5 ether);
        uint256 floor_ = (flap.quote(amt) * 99) / 100;
        vm.prank(GUARDIAN);
        flap.endow(amt, floor_);

        uint256 live = tournament.taskCount();
        vm.expectRevert();
        flap.fundTaskFromPool(live + 1);
        vm.expectRevert();
        flap.fundTaskFromPool(0);
    }

    function test_CannotSponsorATaskThatDoesNotExist() public {
        uint256 amount = 1e15;
        deal(BTCB, SPONSOR, amount);
        uint256 live = tournament.taskCount();

        vm.startPrank(SPONSOR);
        IERC20(BTCB).approve(address(flap), amount);
        vm.expectRevert(bytes(unicode"No such task / 该任务不存在"));
        flap.sponsor(live + 99, amount);
        vm.stopPrank();

        assertEq(IERC20(BTCB).balanceOf(SPONSOR), amount, "the sponsor keeps their tokens");
    }

    /// @notice The headline numbers report the two assets separately, because they are two assets.
    function test_StatsSeparatesTheCoinFromTheToken() public {
        _tax(3 ether);
        uint256 floor_ = _floor(_within(2 ether));
        uint256 amt10_ = _within(2 ether);
        vm.prank(GUARDIAN);
        uint256 pot = flap.endow(amt10_, floor_);

        (, , uint256 unassignedBnb, uint256 committedBtcb, uint256 paidBtcb, ) = flap.stats();
        assertEq(unassignedBnb, 1 ether, "unconverted tax is still BNB");
        assertEq(committedBtcb, pot, "committed is BTCB");
        assertEq(paidBtcb, 0, "nothing paid yet");
    }
}
