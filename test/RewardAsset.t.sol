// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
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
    address internal constant SPONSOR = address(0x5B);

    AssayFlapVault internal flap;

    function setUp() public override {
        vm.createSelectFork(vm.envOr("BSC_RPC", string("https://bsc-rpc.publicnode.com")));
        super.setUp();
        flap = new AssayFlapVault(tournament, address(token), CURATOR);
    }

    /// @dev Tax arrives the way Flap sends it: a plain native transfer.
    function _tax(uint256 amount) internal {
        vm.deal(TAXPAYER, amount);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: amount}("");
        require(ok, "tax transfer failed");
    }

    /// @dev A miner with a real, recorded score.
    function _scoringMiner(address miner, uint256 agentId) internal {
        _enroll(miner, agentId);
        _commit(miner, agentId, Bytecode.padded(), bytes32(agentId));
        vm.warp(commitEnd + 1);
        _reveal(miner, Bytecode.padded(), bytes32(agentId));
        vm.warp(revealEnd + 1);
    }

    // -------------------------------------------------------------------------------------

    function test_TheVaultKnowsWhatItPaysIn() public view {
        assertEq(address(flap.reward()), BTCB, "reward is not BTCB");
        assertEq(IERC20(BTCB).balanceOf(address(flap)), 0, "starts holding none");
        assertTrue(flap.solvent(), "an empty vault is trivially solvent");
    }

    function test_TaxArrivesAsBnbAndIsEntirelyUnassigned() public {
        _tax(3 ether);
        assertEq(flap.unassigned(), 3 ether, "native tax is unassigned by construction");
        assertEq(flap.endowed(), 0, "nothing is behind a task yet");
    }

    /// @notice The whole point: BNB goes in, BTCB comes out, and the bounty is booked in BTCB.
    function test_EndowConvertsToBtcbAndBooksWhatActuallyArrived() public {
        _tax(3 ether);

        uint256 quoted = flap.quote(2 ether);
        assertGt(quoted, 0, "no route from BNB to BTCB");

        vm.prank(CURATOR);
        uint256 got = flap.endow(taskId, 2 ether, (quoted * 99) / 100);

        assertEq(IERC20(BTCB).balanceOf(address(flap)), got, "vault holds exactly what it booked");
        assertEq(flap.endowed(), got, "endowed tracks the tokens, not the coins spent");
        assertEq(flap.bounty(taskId), got, "the bounty is the tokens");
        assertEq(flap.unassigned(), 1 ether, "the unconverted remainder stays native");
        assertTrue(flap.solvent(), "every open bounty is covered");
        assertApproxEqRel(got, quoted, 0.01e18, "booked far from the quote");
    }

    /// @notice The slippage floor is a floor, not a suggestion.
    function test_EndowRevertsBelowTheFloor() public {
        _tax(2 ether);
        uint256 quoted = flap.quote(1 ether);

        vm.prank(CURATOR);
        vm.expectRevert();
        flap.endow(taskId, 1 ether, quoted * 2);

        assertEq(flap.endowed(), 0, "a reverted conversion books nothing");
        assertEq(flap.unassigned(), 2 ether, "and spends nothing");
    }

    function test_OnlyTheCuratorConverts() public {
        _tax(1 ether);
        vm.prank(ALICE);
        vm.expectRevert(AssayFlapVault.NotCurator.selector);
        flap.endow(taskId, 1 ether, 0);
    }

    function test_CannotEndowMoreThanHasArrived() public {
        _tax(1 ether);
        vm.prank(CURATOR);
        vm.expectRevert(AssayFlapVault.NothingUnassigned.selector);
        flap.endow(taskId, 2 ether, 0);
    }

    /// @notice A scoring miner is paid in BTCB, and the native balance never moves for them.
    function test_TheMinerIsPaidInBtcb() public {
        _tax(2 ether);
        vm.prank(CURATOR);
        uint256 pot = flap.endow(taskId, 2 ether, 0);

        _scoringMiner(ALICE, AGENT_ALICE);

        uint256 due = flap.collectable(taskId, ALICE);
        assertGt(due, 0, "a scoring miner is owed something");

        uint256 bnbBefore = ALICE.balance;
        vm.prank(ALICE);
        uint256 got = flap.collect(taskId);

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
        vm.prank(CURATOR);
        flap.endow(taskId, 1 ether, 0);
        _scoringMiner(ALICE, AGENT_ALICE);

        vm.prank(ALICE);
        flap.collect(taskId);
        vm.prank(ALICE);
        vm.expectRevert(AssayFlapVault.AlreadyCollected.selector);
        flap.collect(taskId);
    }

    /// @notice Anyone may make a bounty larger; nobody may make it smaller.
    function test_AnyoneCanSponsorInBtcb() public {
        uint256 amount = 5e15; // 0.005 BTCB
        deal(BTCB, SPONSOR, amount);

        vm.startPrank(SPONSOR);
        IERC20(BTCB).approve(address(flap), amount);
        flap.sponsor(taskId, amount);
        vm.stopPrank();

        assertEq(flap.bounty(taskId), amount, "the sponsorship is the bounty");
        assertEq(flap.endowed(), amount, "and is accounted as open");
        assertTrue(flap.solvent());

        _scoringMiner(ALICE, AGENT_ALICE);
        vm.prank(ALICE);
        assertEq(flap.collect(taskId), amount, "a lone scorer takes the whole sponsored pot");
    }

    /// @notice The headline numbers report the two assets separately, because they are two assets.
    function test_StatsSeparatesTheCoinFromTheToken() public {
        _tax(3 ether);
        vm.prank(CURATOR);
        uint256 pot = flap.endow(taskId, 2 ether, 0);

        (, , uint256 unassignedBnb, uint256 committedBtcb, uint256 paidBtcb, ) = flap.stats();
        assertEq(unassignedBnb, 1 ether, "unconverted tax is still BNB");
        assertEq(committedBtcb, pot, "committed is BTCB");
        assertEq(paidBtcb, 0, "nothing paid yet");
    }
}
