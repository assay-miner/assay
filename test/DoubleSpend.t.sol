// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Stack} from "../script/Stack.sol" ;
import {Guardians} from "./Guardians.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";

/// @notice Two ways the same BTCB could leave the vault twice, and one way a miner's stake could
///         be locked for good. All three were found by pointing an adversarial review at the parts
///         the happy path never reaches.
contract DoubleSpendTest is BaseTest {
    address internal constant BTCB = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8;
    address internal constant TAXPAYER = address(0x7A);

    AssayFlapVault internal flap;
    address internal guardian;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        flap = Stack.newFlapVault(Guardians.TESTNET, tournament, address(token), Stack.newPriceGuard(Guardians.TESTNET));
        guardian = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    }

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

    function _endowTask(uint256 id, uint256 bnb) internal returns (uint256) {
        uint256 floor_ = (flap.quote(bnb) * 97) / 100; // read before the prank; a view consumes it
        vm.prank(guardian);
        flap.endow(bnb, floor_);
        return flap.fundTaskFromPool(id);
    }

    /// @notice A miner who scored but never collected must not be payable out of another task's
    ///         money after the project has already reclaimed their task's bounty.
    /// @dev `collectable` reads `bounty[taskId]` and never looks at `paid[taskId]`, so once
    ///      `reclaimBounty` has set paid == bounty the stale scorer still computes a full share.
    ///      `collect` has no balance check of its own, so it pays it — out of whatever BTCB the
    ///      vault happens to be holding for other tasks. `solvent()` cannot see it: `endowed` is a
    ///      global sum, so a hole in one task's ledger is invisible until the last claimant.
    function test_AReclaimedBountyCannotBePaidFromAnotherTask() public {
        // Task 1: funded, and ALICE scores on it but never collects.
        _tax(0.05 ether);
        uint256 bounty1 = _endowTask(drawnTaskId, _within(0.025 ether));

        _enroll(ALICE, AGENT_ALICE);
        _commitDrawn(ALICE, AGENT_ALICE, drawnTight, bytes32(AGENT_ALICE));
        vm.warp(drawnCommitEnd);
        _revealDrawn(ALICE, drawnTight, bytes32(AGENT_ALICE));

        // Task 2: a second, separately funded task whose money must stay its own. It has to be a
        // drawn task too — the pool pays that lane and no other, so a curated second task would
        // simply have no bounty and the test would prove nothing about keeping two apart.
        uint256 firstDrawn = drawnTaskId;
        vm.warp(uint256(tournament.latestRevealEnd()) + 1);
        _postDrawnFixture();
        uint256 second = drawnTaskId;
        assertGt(second, firstDrawn, "the second draw did not produce a newer task");
        uint256 bounty2 = _endowTask(second, _within(0.025 ether));
        assertGt(bounty2, 0, "the second task was never funded");

        // ALICE sat on her share until the claim window closed, so the project reclaimed task 1.
        (,, uint64 revealEnds,,,,,,) = tournament.tasks(firstDrawn);
        vm.warp(uint256(revealEnds) + tournament.CLAIM_WINDOW());
        vm.prank(CURATOR);
        uint256 reclaimed = flap.reclaimBounty(firstDrawn);
        assertEq(reclaimed, bounty1, "the reclaim did not take the whole bounty");

        // Task 1 is settled to the last wei. There is nothing left in it for anybody.
        assertEq(flap.collectable(firstDrawn, ALICE), 0, "a reclaimed task still shows a collectable share");

        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Nothing to collect / 无可领取"));
        flap.collect(firstDrawn);

        // And the second task's money is untouched.
        assertEq(flap.bounty(second) - flap.paid(second), bounty2, "task 2 was drained");
        assertTrue(flap.solvent(), "the vault cannot cover what its ledger claims");
    }

    /// @notice BNB already promised to a scheduled conversion must not be spendable a second time.
    /// @dev `freeTax()` is the raw balance less `reserved`, and arming escrows nothing — the BNB
    ///      simply stays in the vault — so without that subtraction the same coins could be
    ///      committed twice. The second spender used to be `withdrawUnconverted`, which is gone;
    ///      it is now `endow`, the Guardian's direct conversion, and the failure it would cause is
    ///      unchanged: the scheduler's callback finds less BNB than it priced, the swap fails, the
    ///      fee is spent for nothing and an epoch's tax misses its task's commit window.
    ///
    ///      Asserted against `endow` because that is the path that still exists. Delete the
    ///      `reserved` subtraction in `freeTax()` and the Guardian is handed the armed BNB again.
    function test_AnArmedConversionCannotBeSpentTwice() public {
        _tax(0.05 ether);
        uint256 size = _within(0.02 ether);
        uint256 floor_ = (flap.quote(size) * 97) / 100; // before the prank: a view consumes it
        uint256 fee = flap.triggerService().getFee();
        vm.deal(CURATOR, fee);

        vm.prank(CURATOR);
        flap.triggerConversion{value: fee}();

        // An armed conversion reserves the whole window, so nothing is free — which is the same
        // property stated more strongly than when it reserved only part.
        assertEq(flap.freeTax(), 0, "the armed BNB is still counted as free");
        assertEq(flap.reserved(), 0.05 ether, "the reservation was not recorded");

        // A conversion the Guardian could otherwise price and execute itself, refused on the one
        // ground that matters: the BNB it would spend is already spoken for.
        vm.prank(guardian);
        vm.expectRevert(bytes(unicode"Exceeds unconverted tax / 超过未兑换的税"));
        flap.endow(size, floor_);

        assertGe(address(flap).balance, size, "the armed conversion can no longer be funded");
    }

    /// @notice The Guardian can post a task when the curator cannot.
    /// @dev curator is immutable and this was the tournament's only gate, so a lost or compromised
    ///      key ended task creation permanently — every privileged function on the vault already
    ///      had a Guardian fallback and the tournament had none at all. Tested on a fork because
    ///      the Guardian is a per-chain constant and resolves to zero on a local chain.
    function test_TheGuardianMayPostWhenTheCuratorCannot() public {
        vm.prank(guardian);
        uint256 id = tournament.postTask(inputs, expected, Bytecode.tight(), GAS_CAP,
            uint64(block.timestamp + 600), uint64(block.timestamp + 1200), 0
        );
        assertGt(id, 0, "the Guardian could not post");

        // And a stranger still cannot — the fallback is a second key, not an open door.
        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Not the curator / 非策展方"));
        tournament.postTask(inputs, expected, Bytecode.tight(), GAS_CAP,
            uint64(block.timestamp + 60), uint64(block.timestamp + 120), 0
        );
    }

    /// @notice A task cannot lock a miner's stake beyond a bounded horizon.
    /// @dev `commit` passes `revealEnd` straight to `AgentRoster.lockUntil`, which only ever
    ///      raises `lockedUntil` and has no unlock path and no owner. `postTask` bounded the
    ///      window only from below, so a task posted with `revealEnd = type(uint64).max` locked
    ///      the stake of anybody who entered it for good.
    function test_ATaskCannotLockStakeForever() public {
        uint64 commitEnds = uint64(block.timestamp + 600);
        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Bad window / 时间窗口不合法"));
        tournament.postTask(inputs, expected, Bytecode.tight(), GAS_CAP, commitEnds, type(uint64).max, 0);
    }

    /// @notice And the bound is a real ceiling a task may run right up to, not a formality.
    function test_ATaskMayRunToTheBound() public {
        uint64 span = tournament.MAX_TASK_SPAN();
        uint64 commitEnds = uint64(block.timestamp + 600);
        vm.prank(CURATOR);
        uint256 id = tournament.postTask(inputs, expected, Bytecode.tight(), GAS_CAP, commitEnds, uint64(block.timestamp) + span, 0
        );
        assertGt(id, 0, "a task at exactly the bound was refused");
    }
}
