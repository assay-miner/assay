// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";

/// @notice Whether an epoch's own trading tax reaches that epoch's own task.
///
/// @dev It usually does not, and that is the finding: `CONVERSION_INTERVAL` is five minutes,
///      `tasks/epoch.json` — what the shipped ops flow actually posts — gives a task a sixty-second
///      commit window, and `fundTaskFromPool` refuses once that window has closed. So by the time
///      tax accrued during a task's own commit window converts, that task can no longer receive it;
///      the pool holds it for whichever task is open next.
///
///      Money is never lost or misdirected — `rewardPool` only grows until some task's commit
///      window is open when a call arrives — and the mismatch is a relationship between two
///      operator-chosen numbers, not a defect in `fundTaskFromPool` itself. The second test here is
///      why: the one-shot flag does not consume on an empty pool, so a wider commit window
///      (`commitSeconds >= CONVERSION_INTERVAL`) already lets a later call catch the money. This
///      file makes both halves checkable instead of leaving the claim to an operational comment.
contract PoolTimingTest is BaseTest {
    address internal constant TAXPAYER = address(0x7A);

    AssayFlapVault internal flap;
    address internal guardian;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        flap = new AssayFlapVault(tournament, address(token), CURATOR, new PriceGuard());
        guardian = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    }

    function _post(uint64 commitSpan, uint64 revealSpan) internal returns (uint256 taskId) {
        vm.startPrank(CURATOR);
        token.approve(address(vault), type(uint256).max);
        taskId = tournament.postTask(
            inputs, expected, Bytecode.verbose(), GAS_CAP,
            uint64(block.timestamp) + commitSpan, uint64(block.timestamp) + commitSpan + revealSpan, POT
        );
        vm.stopPrank();
    }

    /// @dev The shipped configuration, quantified. `tasks/epoch.json` carries `commitSeconds: 60`;
    ///      `CONVERSION_INTERVAL` is 300. A conversion that arms at posting cannot execute before
    ///      this task's own commit window has closed, so `fundTaskFromPool` is refused for the
    ///      whole window even once the money exists.
    function test_UnderTheShippedWindowTheEpochsOwnConversionArrivesTooLate() public {
        uint64 shippedCommitSeconds = 60;
        assertLt(
            shippedCommitSeconds,
            flap.CONVERSION_INTERVAL(),
            "the commit window is no longer shorter than the conversion cadence; this test is stale"
        );

        uint256 taskId = _post(shippedCommitSeconds, 60);

        vm.expectRevert(bytes(unicode"Pool is empty / 池中无资金"));
        flap.fundTaskFromPool(taskId);

        // Tax arrives, but only after the cadence's own floor — this is the earliest a self-armed
        // conversion could possibly have executed.
        vm.warp(block.timestamp + flap.CONVERSION_INTERVAL());
        vm.deal(TAXPAYER, 0.05 ether);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: 0.05 ether}("");
        require(ok, "tax transfer failed");
        uint256 floor_ = (flap.quote(0.05 ether) * 99) / 100;
        vm.prank(guardian);
        flap.endow(0.05 ether, floor_);
        assertGt(flap.rewardPool(), 0, "the tax converted; the pool now holds something");

        // But this task's commit window closed at the shipped span, well before the cadence could
        // have delivered it.
        vm.expectRevert(bytes(unicode"Commitment closed / 承诺已截止"));
        flap.fundTaskFromPool(taskId);
    }

    /// @dev The mitigation the shipped config does not use. `fundTaskFromPool`'s empty-pool revert
    ///      happens before the one-shot flag is set, so it does not consume the attempt — a commit
    ///      window wide enough to still be open when the conversion lands can be funded by a second
    ///      call. Nothing here needs a contract change; `commitSeconds` is chosen per task.
    function test_AWindowAsWideAsTheCadenceStillCatchesTheConversion() public {
        uint64 wideCommitSeconds = uint64(300 + 60); // one full cadence, plus room to call

        uint256 taskId = _post(wideCommitSeconds, 60);

        vm.expectRevert(bytes(unicode"Pool is empty / 池中无资金"));
        flap.fundTaskFromPool(taskId);

        vm.warp(block.timestamp + flap.CONVERSION_INTERVAL());
        vm.deal(TAXPAYER, 0.05 ether);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: 0.05 ether}("");
        require(ok, "tax transfer failed");
        uint256 floor_ = (flap.quote(0.05 ether) * 99) / 100;
        vm.prank(guardian);
        flap.endow(0.05 ether, floor_);

        (uint64 commitEnd_,,,) = tournament.taskGates(taskId);
        assertLt(block.timestamp, commitEnd_, "the window closed before the conversion landed");

        uint256 funded = flap.fundTaskFromPool(taskId);
        assertGt(funded, 0, "the wider window still could not catch its own epoch's tax");
    }
}
