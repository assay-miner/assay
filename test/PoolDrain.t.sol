// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";

/// @notice The two ways somebody other than a miner could take the pool.
///
/// @dev Both were reachable on the packaged code and neither had a test. `fundTaskFromPool` is
///      unpermissioned on purpose — it moves money the pool already owes to whichever task is
///      running, so there is no decision in it to protect. What it was missing is that a task has
///      to still be running: scores on a settled task are final, so funding one after the fact
///      hands the pool to whoever already holds a score on it.
contract PoolDrainTest is BaseTest {
    address internal constant BTCB = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8;
    address internal constant TAXPAYER = address(0x7A);
    // A legitimate, enrolled miner. That is the threat model: the drain needs a real score, so
    // the person who can run it is somebody already playing, not an outsider.
    address internal constant ATTACKER = ALICE;
    uint256 internal constant ATTACKER_AGENT = AGENT_ALICE;

    AssayFlapVault internal flap;
    address internal guardian;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        flap = new AssayFlapVault(tournament, address(token), CURATOR, new PriceGuard());
        guardian = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    }

    /// @dev Fills the pool without putting it behind any task.
    function _fillPool(uint256 bnb) internal returns (uint256) {
        vm.deal(TAXPAYER, bnb);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: bnb}("");
        require(ok, "tax transfer failed");

        uint256 cap = flap.maxConvertible();
        uint256 amount = bnb > cap ? cap : bnb;
        // The quote is read before the prank: a view call in an argument list consumes it.
        uint256 floor_ = (flap.quote(amount) * 99) / 100;
        vm.prank(guardian);
        flap.endow(amount, floor_);
        return flap.rewardPool();
    }

    /// @dev Leaves `miner` holding a final, non-zero score on the setUp task, which nobody funded.
    function _settleWithAScore(address miner, uint256 agentId) internal {
        _enroll(miner, agentId);
        _commit(miner, agentId, Bytecode.padded(), bytes32(agentId));
        vm.warp(commitEnd + 1);
        _reveal(miner, Bytecode.padded(), bytes32(agentId));
        vm.warp(revealEnd + 1);
    }

    // ------------------------------------------------------------ funding a settled task

    /// @dev The drain. Break the gate in AssayFlapVault.fundTaskFromPool and this passes the
    ///      revert check by never reverting, then shows the attacker holding the whole pool.
    function test_ASettledTaskCannotBeFundedAndCollectedAtOnce() public {
        _settleWithAScore(ATTACKER, ATTACKER_AGENT);

        uint256 pool = _fillPool(0.05 ether);
        assertGt(pool, 0, "the pool has to hold something for this to be a drain");
        assertEq(flap.bounty(taskId), 0, "the task under attack was never funded");

        // Scores are already final here, so funding now would divide a pot among people who are
        // done competing for it — and this miner is the only one of them.
        vm.prank(ATTACKER);
        // The gate names commitment, not settlement: a settled task is past commitEnd too.
        vm.expectRevert(bytes(unicode"Commitment closed / 承诺已截止"));
        flap.fundTaskFromPool(taskId);

        // And with the money still in the pool there is nothing to collect.
        vm.prank(ATTACKER);
        vm.expectRevert(bytes(unicode"Nothing to collect / 无可领取"));
        flap.collect(taskId);

        assertEq(flap.rewardPool(), pool, "the pool did not move");
        assertEq(IERC20(BTCB).balanceOf(ATTACKER), 0, "the attacker took nothing");
    }

    /// @dev The same call is the intended one while the task is live, so the gate has to be the
    ///      task's state and not a permission. Without this the fix could be "nobody can fund".
    function test_ALiveTaskStillFunds() public {
        uint256 pool = _fillPool(0.05 ether);
        vm.prank(ATTACKER);
        uint256 funded = flap.fundTaskFromPool(taskId);
        assertEq(funded, pool, "a live task takes the whole pool");
        assertEq(flap.bounty(taskId), pool, "and it lands on the bounty");
    }

    // ------------------------------------------------------------ blocking a task with dust

    /// @dev `sponsor` is open to anyone by design. The old one-shot gate asked whether the bounty
    ///      was zero, which let one wei of somebody else's BTCB make a task permanently unfundable.
    ///      Restore that gate and this reverts with "Already funded / 已注资".
    function test_DustSponsorshipCannotBlockPoolFunding() public {
        uint256 pool = _fillPool(0.05 ether);

        deal(BTCB, ATTACKER, 1);
        vm.startPrank(ATTACKER);
        IERC20(BTCB).approve(address(flap), 1);
        flap.sponsor(taskId, 1);
        vm.stopPrank();

        assertEq(flap.bounty(taskId), 1, "the dust is on the bounty");

        uint256 funded = flap.fundTaskFromPool(taskId);
        assertEq(funded, pool, "the pool still moves");
        assertEq(flap.bounty(taskId), pool + 1, "and it sits alongside the sponsorship");
    }

    // ------------------------------------------------ the reveal window: the field is frozen

    /// @dev The half the first fix missed. Commitment closes at commitEnd, so across the whole
    ///      reveal window nobody new can enter while the pool could still be moved onto the task.
    ///      Anyone already committed could wait for that window and take a pot no one else could
    ///      still compete for. Point the gate back at revealEnd and this passes by not reverting.
    function test_ATaskInItsRevealWindowCannotStillBeFunded() public {
        _enroll(ATTACKER, ATTACKER_AGENT);
        _commit(ATTACKER, ATTACKER_AGENT, Bytecode.padded(), bytes32(ATTACKER_AGENT));

        // Past commitment, before settlement: the field is closed, the task is not.
        vm.warp(commitEnd + 1);
        uint256 pool = _fillPool(0.05 ether);
        assertGt(pool, 0, "the pool has to hold something for this to be worth taking");
        assertLt(block.timestamp, revealEnd, "still inside the reveal window");

        vm.prank(ATTACKER);
        vm.expectRevert(bytes(unicode"Commitment closed / 承诺已截止"));
        flap.fundTaskFromPool(taskId);

        assertEq(flap.rewardPool(), pool, "the pool did not move");
    }

    // ------------------------------------------------ a bounty that moves after settlement

    /// @dev `collectable` reads the live bounty as the pot, so a sponsorship landing between two
    ///      equal-scoring miners' collections pays the second more than the first. The gate that
    ///      stops it was written for fundTaskFromPool and not for sponsor. Remove it here and this
    ///      passes by not reverting.
    function test_ASettledTaskCannotBeSponsored() public {
        _fillPool(0.05 ether);
        flap.fundTaskFromPool(taskId);
        vm.warp(revealEnd + 1);

        deal(BTCB, ATTACKER, 1e15);
        vm.startPrank(ATTACKER);
        IERC20(BTCB).approve(address(flap), 1e15);
        vm.expectRevert(bytes(unicode"Settled / 已结算"));
        flap.sponsor(taskId, 1e15);
        vm.stopPrank();
    }

    /// @dev And the same call is still the intended one while the task is live, so the gate is the
    ///      task's state and not a permission.
    function test_ALiveTaskCanStillBeSponsored() public {
        _fillPool(0.05 ether);
        uint256 funded = flap.fundTaskFromPool(taskId);

        deal(BTCB, ATTACKER, 1e15);
        vm.startPrank(ATTACKER);
        IERC20(BTCB).approve(address(flap), 1e15);
        flap.sponsor(taskId, 1e15);
        vm.stopPrank();

        assertEq(flap.bounty(taskId), funded + 1e15, "the sponsorship landed");
    }

    /// @dev The one-shot rule still has to hold, or the pool could be moved onto one task twice.
    function test_PoolFundsATaskOnlyOnce() public {
        _fillPool(0.05 ether);
        flap.fundTaskFromPool(taskId);

        _fillPool(0.05 ether);
        vm.expectRevert(bytes(unicode"Already funded / 已注资"));
        flap.fundTaskFromPool(taskId);
    }
}
