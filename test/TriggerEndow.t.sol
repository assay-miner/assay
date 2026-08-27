// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {IFlapTriggerService} from "../src/flap/IFlapTriggerService.sol";

/// @notice The scheduled conversion path, against Flap's real trigger service on a fork.
///
/// @dev The point of scheduling is not that it is a nicer API. It is that the party who prices a
///      conversion is no longer the party who submits it, which is what removes the ordering an
///      insider could arrange around. These tests are written against that claim: who may
///      schedule, who may execute, what happens when execution fails, and whether a request can
///      end up stuck with no way to re-arm it.
contract TriggerEndowTest is BaseTest {
    address internal constant BTCB = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8;
    address internal constant TRIGGER = 0x560E9830926C9e0EB98a59c6b9902383Fc0D9Eb2;
    address internal constant TAXPAYER = address(0x7A);

    AssayFlapVault internal flap;
    address internal guardian;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        flap = new AssayFlapVault(tournament, address(token), CURATOR);
        guardian = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    }

    function _tax(uint256 amount) internal {
        vm.deal(TAXPAYER, amount);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: amount}("");
        require(ok, "tax transfer failed");
    }

    function _schedule(uint256 bnb) internal returns (uint256 requestId) {
        uint256 floor_ = (flap.quote(bnb) * 99) / 100;
        uint256 fee = flap.schedulerFee();
        vm.deal(CURATOR, fee);
        vm.prank(CURATOR);
        return flap.scheduleEndow{value: fee}(taskId, bnb, floor_);
    }

    // ---------------------------------------------------------------- the service is real

    function test_TheSchedulerIsLiveAndPricesItself() public view {
        assertGt(TRIGGER.code.length, 0, "no trigger service on this chain");
        assertEq(address(flap.triggerService()), TRIGGER, "vault points elsewhere");
        assertGt(flap.schedulerFee(), 0, "fee reads as free");
        assertEq(flap.schedulerFee(), IFlapTriggerService(TRIGGER).getFee(), "fee is not read live");
    }

    // ---------------------------------------------------------------- who may do what

    function test_SchedulingRegistersARealRequest() public {
        _tax(0.05 ether);
        uint256 id = _schedule(0.05 ether);

        IFlapTriggerService.TriggerRequest memory r = IFlapTriggerService(TRIGGER).getRequest(id);
        assertEq(r.requester, address(flap), "the vault is not the requester");
        assertEq(uint8(r.status), 0, "request is not PENDING");

        (uint128 bnbAmount,, uint256 storedTask) = flap.scheduled(id);
        assertEq(bnbAmount, 0.05 ether, "amount not stored");
        assertEq(storedTask, taskId, "task not stored");
        assertEq(flap.unassigned(), 0.05 ether, "scheduling must not move the tax yet");
    }

    function test_OnlyTheCuratorOrGuardianSchedules() public {
        _tax(0.05 ether);
        uint256 floor_ = (flap.quote(0.05 ether) * 99) / 100;
        uint256 fee = flap.schedulerFee();

        vm.deal(ALICE, fee);
        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Only the curator may schedule / 只有策展方可以安排兑换"));
        flap.scheduleEndow{value: fee}(taskId, 0.05 ether, floor_);
    }

    /// @notice The floor is bounded where it is set, not where it is executed.
    function test_SchedulingRefusesAFloorAnInsiderCouldSandwich() public {
        _tax(0.05 ether);
        uint256 fee = flap.schedulerFee();
        vm.deal(CURATOR, fee * 2);

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Slippage floor is too low / 滑点下限过低"));
        flap.scheduleEndow{value: fee}(taskId, 0.05 ether, 0);
    }

    function test_ChangeGoesBackInsteadOfBecomingBounty() public {
        _tax(0.05 ether);
        uint256 floor_ = (flap.quote(0.05 ether) * 99) / 100;
        uint256 fee = flap.schedulerFee();
        vm.deal(CURATOR, fee + 1 ether);

        vm.prank(CURATOR);
        flap.scheduleEndow{value: fee + 1 ether}(taskId, 0.05 ether, floor_);

        assertEq(CURATOR.balance, 1 ether, "change was kept");
        assertEq(flap.unassigned(), 0.05 ether, "the fee leaked into the tax");
    }

    // ---------------------------------------------------------------- execution

    /// @notice The scheduler's address is the only thing that can drive the callback.
    function test_NobodyButTheSchedulerCanFireTheCallback() public {
        _tax(0.05 ether);
        uint256 id = _schedule(0.05 ether);

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Only the trigger service / 仅限调度服务"));
        flap.trigger(id);

        vm.prank(guardian);
        vm.expectRevert(bytes(unicode"Only the trigger service / 仅限调度服务"));
        flap.trigger(id);
    }

    /// @notice The whole point, end to end: the curator priced it, the service executed it.
    function test_TheServiceExecutesWhatTheCuratorPriced() public {
        _tax(0.05 ether);
        uint256 id = _schedule(0.05 ether);

        vm.prank(TRIGGER);
        flap.trigger(id);

        assertGt(flap.bounty(taskId), 0, "nothing was booked");
        assertEq(flap.unassigned(), 0, "the tax was not converted");
        assertTrue(flap.solvent(), "vault is short");

        (uint128 left,,) = flap.scheduled(id);
        assertEq(left, 0, "the request survived execution");
    }

    function test_AnUnknownRequestIdIsRefused() public {
        vm.prank(TRIGGER);
        vm.expectRevert(bytes(unicode"No such scheduled conversion / 没有这笔已安排的兑换"));
        flap.trigger(999_999);
    }

    function test_TheSameRequestCannotExecuteTwice() public {
        _tax(0.05 ether);
        uint256 id = _schedule(0.05 ether);

        vm.prank(TRIGGER);
        flap.trigger(id);

        vm.prank(TRIGGER);
        vm.expectRevert(bytes(unicode"No such scheduled conversion / 没有这笔已安排的兑换"));
        flap.trigger(id);
    }

    // ---------------------------------------------------------------- failure and re-arming

    /// @notice A conversion the market has moved past must fail loudly and stay retryable.
    ///
    /// @dev This is the deadlock the integration guide warns about. If the callback swallowed the
    ///      failure, the service would record EXECUTED, `retryTrigger` would refuse the request
    ///      forever, and the stored conversion would be consumed with nothing booked. It reverts
    ///      instead — and because the revert also undoes the deletion, the request is still there
    ///      to be tried again.
    function test_AFailedConversionRevertsAndStaysRetryable() public {
        _tax(0.05 ether);

        // A floor the pool cannot meet: schedule at a real one, then move the market against it.
        uint256 id = _schedule(0.05 ether);
        deal(BTCB, address(this), 0);

        // Force the swap to fail by asking the router for an impossible output at execution time.
        // The stored floor is fine; the pool is what changed. Simulated by draining the vault's
        // native balance so the swap cannot be funded.
        vm.deal(address(flap), 0);

        vm.prank(TRIGGER);
        vm.expectRevert();
        flap.trigger(id);

        // The record survived, because the revert undid the deletion along with everything else.
        (uint128 bnbAmount,, uint256 storedTask) = flap.scheduled(id);
        assertEq(bnbAmount, 0.05 ether, "the request was consumed by a failure");
        assertEq(storedTask, taskId, "the task was lost");
    }

    function test_ACancelledRequestCannotFireLater() public {
        _tax(0.05 ether);
        uint256 id = _schedule(0.05 ether);

        vm.prank(CURATOR);
        flap.cancelScheduledEndow(id);

        (uint128 left,,) = flap.scheduled(id);
        assertEq(left, 0, "cancel left the record behind");

        vm.prank(TRIGGER);
        vm.expectRevert(bytes(unicode"No such scheduled conversion / 没有这笔已安排的兑换"));
        flap.trigger(id);

        assertEq(flap.unassigned(), 0.05 ether, "the tax moved on a cancelled request");
    }

    function test_OnlyTheCuratorOrGuardianCancels() public {
        _tax(0.05 ether);
        uint256 id = _schedule(0.05 ether);

        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Only the curator may cancel / 只有策展方可以取消"));
        flap.cancelScheduledEndow(id);

        vm.prank(guardian);
        flap.cancelScheduledEndow(id);
    }

    // ---------------------------------------------------------------- the escape hatch

    /// @notice `endow` still exists for the case where the scheduler itself is unavailable, and
    ///         it is the Guardian's alone — not the curator's, which is what closed M-02.
    function test_TheDirectPathIsTheGuardiansAlone() public {
        _tax(0.05 ether);
        uint256 floor_ = (flap.quote(0.05 ether) * 99) / 100;

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Only the guardian / 仅限守护者"));
        flap.endow(taskId, 0.05 ether, floor_);

        vm.prank(guardian);
        assertGt(flap.endow(taskId, 0.05 ether, floor_), 0, "the guardian cannot convert");
    }

    /// @notice Both paths book through the same code, so neither can drift from the other.
    function test_BothPathsBookIdentically() public {
        _tax(0.10 ether);

        uint256 id = _schedule(0.05 ether);
        vm.prank(TRIGGER);
        flap.trigger(id);
        uint256 viaScheduler = flap.bounty(taskId);

        uint256 floor_ = (flap.quote(0.05 ether) * 99) / 100;
        vm.prank(guardian);
        uint256 viaHatch = flap.endow(taskId, 0.05 ether, floor_);

        assertEq(flap.bounty(taskId), viaScheduler + viaHatch, "the two paths book differently");
        assertEq(flap.endowed(), flap.bounty(taskId), "the ledger disagrees with the task");
    }
}
