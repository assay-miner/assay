// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
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
        flap = new AssayFlapVault(tournament, address(token), CURATOR);
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
        return flap.endow(taskId, bnb, floor_);
    }

    function _scoringMiner(address miner, uint256 agentId) internal {
        _enroll(miner, agentId);
        _commit(miner, agentId, Bytecode.padded(), bytes32(agentId));
        vm.warp(commitEnd + 1);
        _reveal(miner, Bytecode.padded(), bytes32(agentId));
        vm.warp(revealEnd + 1);
    }

    // ------------------------------------------------ a window nobody mined

    /// @notice Tax that was never put behind a task comes back, instead of sitting here forever.
    function test_TaxFromAnEmptyWindowGoesToTheProject() public {
        _tax(0.05 ether);
        uint256 before = CURATOR.balance;

        vm.prank(CURATOR);
        uint256 sent = flap.withdrawUnconverted(0);

        assertEq(sent, 0.05 ether, "the whole window did not come back");
        assertEq(CURATOR.balance, before + 0.05 ether, "it did not arrive");
        assertEq(flap.unassigned(), 0, "something was left behind");
    }

    /// @notice And it cannot touch what is already behind a task.
    function test_WithdrawingCannotReachAnEndowedBounty() public {
        _tax(0.10 ether);
        uint256 pot = _endow(_within(0.05 ether));

        vm.prank(CURATOR);
        flap.withdrawUnconverted(0);

        assertEq(flap.bounty(taskId), pot, "the bounty moved");
        assertEq(flap.endowed(), pot, "the ledger moved");
        assertTrue(flap.solvent(), "vault is short");
        assertEq(IERC20(BTCB).balanceOf(address(flap)), pot, "BTCB left the vault");
    }

    function test_OnlyTheCuratorOrGuardianWithdraws() public {
        _tax(0.05 ether);
        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Only the curator / 仅限策展方"));
        flap.withdrawUnconverted(0);
    }

    function test_WithdrawingNothingIsAnError() public {
        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"No unconverted tax / 无未兑换的税"));
        flap.withdrawUnconverted(0);
    }

    // ------------------------------------------------ a task nobody entered

    /// @notice A bounty on a task that drew no submissions returns once reveal closes.
    function test_AnUnwonBountyComesBack() public {
        _tax(0.05 ether);
        uint256 pot = _endow(_within(0.05 ether));

        vm.warp(revealEnd + 1);
        uint256 before = IERC20(BTCB).balanceOf(CURATOR);

        vm.prank(CURATOR);
        uint256 got = flap.reclaimBounty(taskId);

        assertEq(got, pot, "not all of it came back");
        assertEq(IERC20(BTCB).balanceOf(CURATOR), before + pot, "it did not arrive");
        assertEq(flap.endowed(), 0, "the ledger still claims it is funded");
        assertTrue(flap.solvent());
    }

    /// @notice Not before the window closes — a miner may still be about to reveal.
    function test_ABountyCannotBeReclaimedEarly() public {
        _tax(0.05 ether);
        _endow(_within(0.05 ether));

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Not settled yet / 尚未结算"));
        flap.reclaimBounty(taskId);
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
        flap.reclaimBounty(taskId);

        // The miner takes their share on their own schedule.
        vm.prank(ALICE);
        assertEq(flap.collect(taskId), pot, "the sole scorer did not get the pot");
    }

    /// @notice Once the tournament's claim window has passed, the remainder is reclaimable.
    function test_TheRemainderComesBackAfterTheClaimWindow() public {
        _tax(0.05 ether);
        uint256 pot = _endow(_within(0.05 ether));
        _scoringMiner(ALICE, AGENT_ALICE);

        vm.warp(revealEnd + tournament.CLAIM_WINDOW() + 1);
        vm.prank(CURATOR);
        uint256 got = flap.reclaimBounty(taskId);

        assertEq(got, pot, "the unclaimed remainder did not come back");
        assertEq(flap.endowed(), 0, "the ledger disagrees");

        // And the miner who slept through the window can no longer take it twice.
        vm.prank(ALICE);
        vm.expectRevert();
        flap.collect(taskId);
    }

    function test_ABountyCannotBeReclaimedTwice() public {
        _tax(0.05 ether);
        _endow(_within(0.05 ether));
        vm.warp(revealEnd + 1);

        vm.prank(CURATOR);
        flap.reclaimBounty(taskId);

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Nothing left / 已无剩余"));
        flap.reclaimBounty(taskId);
    }

    function test_OnlyTheCuratorOrGuardianReclaims() public {
        _tax(0.05 ether);
        _endow(_within(0.05 ether));
        vm.warp(revealEnd + 1);

        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Only the curator / 仅限策展方"));
        flap.reclaimBounty(taskId);
    }
}
