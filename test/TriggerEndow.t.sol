// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IPancakeRouter02} from "../src/interfaces/IPancakeRouter02.sol";

/// @dev Test-only. The production IPancakeRouter02 carries just the three functions the vault
///      actually calls, deliberately — an unused signature is one that drifts unnoticed — so the
///      one this file needs to move the pair lives here instead of being added there.
interface IPairMover {
    function WETH() external view returns (address);
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

import {BaseTest} from "./Base.t.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
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
    address internal constant ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    /// @dev Mirrors AssayFlapVault.MAX_ENDOW_SLIPPAGE_BPS, which is private. Asserted against the
    ///      vault's own arming behaviour below rather than trusted: if the contract's value changed
    ///      and this did not, the floor computed here would not match and the test would fail.
    uint256 internal constant SLIPPAGE_BPS = 300;

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

    function _schedule(uint256 bnb) internal returns (uint256 requestId) {
        uint256 floor_ = (flap.quote(bnb) * 99) / 100;
        uint256 fee = flap.schedulerFee();
        vm.deal(CURATOR, fee);
        vm.prank(CURATOR);
        return flap.triggerConversion{value: fee}();
    }

    // ------------------------------------------------- the vault arming itself pays its own fee

    /// @dev The self-arming path is the second call site of the fee netting and never got it.
    ///      `triggerConversion` subtracts the fee the caller sent; `trigger()` re-arms with
    ///      `_arm(fee, 0)`, where the fee leaves the vault's own balance — which is tax — and the
    ///      old code reserved the un-netted amount. It over-reserved by exactly one fee, and the
    ///      next callback then tried to swap more BNB than the vault held.
    ///
    ///      The assertion is on the newly armed request and not on cumulative `reserved`, and the
    ///      vault is left with no spare balance. The first version of this test funded the vault
    ///      with twenty fees of slack and passed with the bug still in place, which is worse than
    ///      having no test: over-reserving by one fee cannot break an invariant that has twenty
    ///      fees of room. Delete the `if (incoming == 0)` block in `_arm` and this fails.
    function test_SelfArmingArmsOnlyWhatTheVaultCanPay() public {
        _tax(_within(0.05 ether));
        uint256 id = _schedule(_within(0.05 ether));
        assertGt(id, 0, "the first conversion armed");

        vm.warp(block.timestamp + flap.CONVERSION_INTERVAL() + 1);

        // Fresh tax for exactly one more window, and nothing spare. FEE_COVER_MULTIPLE means the
        // window has to be worth more than ten fees before the vault will arm at all.
        uint256 fee = flap.schedulerFee();
        _tax(fee * 12);

        vm.recordLogs();
        vm.prank(TRIGGER);
        flap.trigger(id);

        // Find the request the vault armed for itself inside that callback.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 armed;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(flap)
                    && logs[i].topics[0] == keccak256("ConversionScheduled(uint256,uint256,uint256)")
            ) {
                armed = uint256(logs[i].topics[1]);
            }
        }
        assertGt(armed, 0, "the callback armed the next window");

        (uint128 bnbAmount,) = flap.scheduled(armed);
        assertLe(
            uint256(bnbAmount),
            address(flap).balance,
            "the vault armed a swap larger than the BNB it holds: the next callback cannot pay it"
        );
    }

    // ------------------------------------------------- the fee floor binds only the self-arm

    /// @dev The economics floor exists because the self-arming path buys the scheduler out of tax.
    ///      A caller who supplies the fee themselves spends none, so the floor has no claim on them
    ///      — and `triggerConversion` is the restart for a stalled chain, so refusing it in exactly
    ///      the low-tax case was refusing it when it is most needed. Move the check back outside
    ///      `if (incoming == 0)` and this fails.
    function test_ASmallWindowStillConvertsWhenTheCallerPaysTheFee() public {
        uint256 fee = flap.schedulerFee();

        // Under the floor: more than one fee, so there is something to convert, but well under the
        // ten the self-arming path demands.
        uint256 small = fee * 3;
        _tax(small);
        assertLt(flap.freeTax(), fee * flap.FEE_COVER_MULTIPLE(), "the window is under the floor");

        vm.deal(TAXPAYER, fee);
        vm.prank(TAXPAYER);
        uint256 id = flap.triggerConversion{value: fee}();
        assertGt(id, 0, "the manual caller paid the fee and was still refused");
    }

    /// @dev The other half: the same window must NOT arm itself, because that one does spend tax.
    function test_ASmallWindowStillDoesNotArmItself() public {
        uint256 fee = flap.schedulerFee();
        uint256 amount = _within(0.05 ether);
        _tax(amount);
        uint256 id = _schedule(amount);
        vm.warp(block.timestamp + flap.CONVERSION_INTERVAL() + 1);

        // Leave only a sliver behind, under the floor.
        _tax(fee * 3);

        vm.recordLogs();
        vm.prank(TRIGGER);
        flap.trigger(id);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool armed;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(flap)
                    && logs[i].topics[0] == keccak256("ConversionScheduled(uint256,uint256,uint256)")
            ) armed = true;
        }
        assertFalse(armed, "a window worth less than ten fees armed itself out of tax");
    }

    // ------------------------------------------------- the floor is re-priced at execution

    /// @dev The stored floor is minutes old when the service calls, and the service picks its own
    ///      moment. If BTCB moved up in between, that floor tolerates far more than the 3% it was
    ///      meant to and the difference is free for anyone watching. `trigger` now takes the
    ///      stricter of the stored floor and one priced at execution.
    ///
    ///      The move has to be real for this to test anything: the price is pushed in the direction
    ///      that makes the stored floor too loose, and the assertion is that the vault still came
    ///      away with what the fresh price entitled it to. Remove the `fresh > s.minRewardOut`
    ///      selection in `trigger` and this fails.
    function test_TheFloorIsRepricedWhenTheMarketMovedInOurFavour() public {
        uint256 amount = _within(0.05 ether);
        _tax(amount);
        uint256 id = _schedule(amount);
        assertGt(id, 0, "the conversion armed");

        uint256 floorAtArming = (flap.quote(amount) * (10_000 - SLIPPAGE_BPS)) / 10_000;

        // Move the pair so a given amount of BNB buys more BTCB than it did at arming: sell BTCB in,
        // which raises the BTCB side of the reserves and lowers the BNB side.
        address whale = makeAddr("whale");
        uint256 push = 2 ether;
        deal(BTCB, whale, push);
        address[] memory back = new address[](2);
        back[0] = BTCB;
        back[1] = IPairMover(ROUTER).WETH();
        vm.startPrank(whale);
        IERC20(BTCB).approve(ROUTER, push);
        IPairMover(ROUTER).swapExactTokensForETH(push, 0, back, whale, block.timestamp);
        vm.stopPrank();

        uint256 floorAtExecution = (flap.quote(amount) * (10_000 - SLIPPAGE_BPS)) / 10_000;
        assertGt(
            floorAtExecution,
            floorAtArming,
            "the pair did not actually move; this test proves nothing unless it does"
        );

        vm.warp(block.timestamp + flap.CONVERSION_INTERVAL() + 1);

        // Assert the floor the router is HANDED, not the amount that comes back. The first version
        // of this test asserted the output was at least the fresh floor, which is true whether or
        // not the floor is enforced: nothing was extracting the difference, so the swap returned
        // the full market amount either way. It passed with the entire fix deleted.
        //
        // `swapExactETHForTokens` takes amountOutMin first, so the selector plus that one value is
        // a calldata prefix, and expectCall matches on the prefix.
        vm.expectCall(
            ROUTER,
            abi.encodeWithSelector(
                IPancakeRouter02.swapExactETHForTokens.selector, floorAtExecution
            )
        );
        vm.prank(TRIGGER);
        flap.trigger(id);
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
        uint256 id = _schedule(_within(0.05 ether));

        IFlapTriggerService.TriggerRequest memory r = IFlapTriggerService(TRIGGER).getRequest(id);
        assertEq(r.requester, address(flap), "the vault is not the requester");
        assertEq(uint8(r.status), 0, "request is not PENDING");

        // A scheduled conversion no longer carries a task. Naming a task and naming an amount in
        // the same call was where the curator's discretion lived, so the field is gone rather than
        // defaulted.
        (uint128 bnbAmount,) = flap.scheduled(id);
        assertGt(bnbAmount, 0, "amount not stored");
        // Scheduling reserves the whole epoch's tax, so freeTax falls to zero and the raw balance
        // is untouched — the BNB has not moved, it is spoken for.
        assertEq(flap.freeTax(), 0, "scheduling did not reserve the tax");
        assertEq(address(flap).balance, 0.05 ether, "scheduling moved the tax");
        assertEq(flap.reserved(), 0.05 ether, "the reservation was not recorded");
    }

    /// @notice Anybody may schedule a conversion. There is nothing left in it to abuse.
    /// @dev This asserted that only the curator or Guardian could schedule. That check is gone,
    ///      and deliberately: the call takes no task, no amount and no floor, so a caller supplies
    ///      only the fee. Review asked for the conversion to be permissionless and bounded by
    ///      rules rather than by a name, and a permission was the last thing standing in for one.
    function test_AnyoneMaySchedule() public {
        _tax(0.05 ether);
        uint256 fee = flap.schedulerFee();
        vm.deal(ALICE, fee);
        vm.prank(ALICE);
        uint256 id = flap.triggerConversion{value: fee}();
        assertGt(id, 0, "a stranger could not schedule");
    }

    /// @notice The floor is derived, so there is no floor to supply badly.
    /// @dev This used to check that a floor far below spot was refused. There is no floor
    ///      parameter any more — the vault computes it from the pool at call time — so the check
    ///      is now that what it computed sits within the impact bound it enforces everywhere else.
    function test_TheDerivedFloorSitsInsideTheImpactBound() public {
        _tax(0.05 ether);
        uint256 fee = flap.schedulerFee();
        vm.deal(ALICE, fee);
        vm.prank(ALICE);
        uint256 id = flap.triggerConversion{value: fee}();

        (uint128 amount, uint128 floorOut) = flap.scheduled(id);
        uint256 spot = flap.quote(amount);
        // Same arithmetic as the contract, including the truncation: multiplying the floor back
        // up instead compares against a number the division already rounded away from.
        assertEq(uint256(floorOut), (spot * (10_000 - 300)) / 10_000, "the derived floor is not the bound");
        assertLe(uint256(floorOut), spot, "the derived floor is above spot");
    }

    function test_ChangeGoesBackInsteadOfBecomingBounty() public {
        _tax(0.05 ether);
        uint256 floor_ = (flap.quote(_within(0.05 ether)) * 99) / 100;
        uint256 fee = flap.schedulerFee();
        vm.deal(CURATOR, fee + 1 ether);

        vm.prank(CURATOR);
        flap.triggerConversion{value: fee + 1 ether}();

        assertEq(CURATOR.balance, 1 ether, "change was kept");
        assertEq(address(flap).balance, 0.05 ether, "the fee leaked into the tax");
    }

    // ---------------------------------------------------------------- execution

    /// @notice The scheduler's address is the only thing that can drive the callback.
    function test_NobodyButTheSchedulerCanFireTheCallback() public {
        _tax(0.05 ether);
        uint256 id = _schedule(_within(0.05 ether));

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Only the scheduler / 仅限调度器"));
        flap.trigger(id);

        vm.prank(guardian);
        vm.expectRevert(bytes(unicode"Only the scheduler / 仅限调度器"));
        flap.trigger(id);
    }

    /// @notice The service executes what the vault priced, and it lands in the pool.
    function test_TheServiceExecutesWhatTheVaultPriced() public {
        _tax(0.05 ether);
        uint256 fee = flap.schedulerFee();
        vm.deal(ALICE, fee);
        vm.prank(ALICE);
        uint256 id = flap.triggerConversion{value: fee}();
        (uint128 amount, uint128 floorOut) = flap.scheduled(id);

        uint256 poolBefore = flap.rewardPool();
        vm.prank(TRIGGER);
        flap.trigger(id);

        assertGe(flap.rewardPool() - poolBefore, uint256(floorOut), "the swap came in under its own floor");
        assertEq(flap.reserved(), 0, "the reservation outlived the conversion");
        assertGt(uint256(amount), 0, "nothing was scheduled");
        assertTrue(flap.solvent());
    }

    function test_AnUnknownRequestIdIsRefused() public {
        vm.prank(TRIGGER);
        vm.expectRevert(bytes(unicode"No such request / 无此请求"));
        flap.trigger(999_999);
    }

    function test_TheSameRequestCannotExecuteTwice() public {
        _tax(0.05 ether);
        uint256 id = _schedule(_within(0.05 ether));

        vm.prank(TRIGGER);
        flap.trigger(id);

        vm.prank(TRIGGER);
        vm.expectRevert(bytes(unicode"No such request / 无此请求"));
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
        uint256 id = _schedule(_within(0.05 ether));
        deal(BTCB, address(this), 0);

        // Force the swap to fail by asking the router for an impossible output at execution time.
        // The stored floor is fine; the pool is what changed. Simulated by draining the vault's
        // native balance so the swap cannot be funded.
        vm.deal(address(flap), 0);

        vm.prank(TRIGGER);
        vm.expectRevert();
        flap.trigger(id);

        // The record survived, because the revert undid the deletion along with everything else.
        (uint128 bnbAmount,) = flap.scheduled(id);
        assertGt(bnbAmount, 0, "the request was consumed by a failure");
    }

    function test_ACancelledRequestCannotFireLater() public {
        _tax(0.05 ether);
        uint256 id = _schedule(_within(0.05 ether));

        vm.prank(CURATOR);
        flap.cancelConversion(id);

        (uint128 left,) = flap.scheduled(id);
        assertEq(left, 0, "cancel left the record behind");

        vm.prank(TRIGGER);
        vm.expectRevert(bytes(unicode"No such request / 无此请求"));
        flap.trigger(id);

        assertEq(flap.freeTax(), 0.05 ether, "the tax moved on a cancelled request");
    }

    function test_OnlyTheCuratorOrGuardianCancels() public {
        _tax(0.05 ether);
        uint256 id = _schedule(_within(0.05 ether));

        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Only the curator / 仅限策展方"));
        flap.cancelConversion(id);

        vm.prank(guardian);
        flap.cancelConversion(id);
    }

    // ---------------------------------------------------------------- the escape hatch

    /// @notice `endow` still exists for the case where the scheduler itself is unavailable, and
    ///         it is the Guardian's alone — not the curator's, which is what closed M-02.
    function test_TheDirectPathIsTheGuardiansAlone() public {
        _tax(0.05 ether);
        uint256 floor_ = (flap.quote(_within(0.05 ether)) * 99) / 100;

        uint256 amt3_ = _within(0.05 ether);
        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Only the guardian / 仅限守护者"));
        flap.endow(amt3_, floor_);

        uint256 amt4_ = _within(0.05 ether);
        vm.prank(guardian);
        assertGt(flap.endow(amt4_, floor_), 0, "the guardian cannot convert");
    }

    /// @notice Both conversion paths land in the same pool, so neither can book differently.
    /// @dev They used to book into a task each named, which is exactly where the two could drift.
    ///      Neither names anything now.
    function test_BothPathsBookIntoTheSamePool() public {
        _tax(0.1 ether);

        uint256 direct = _within(0.02 ether);
        uint256 floorD = (flap.quote(direct) * 97) / 100;
        vm.prank(guardian);
        uint256 outD = flap.endow(direct, floorD);
        assertEq(flap.rewardPool(), outD, "the guardian path did not credit the pool");

        vm.warp(block.timestamp + flap.CONVERSION_INTERVAL());
        uint256 fee = flap.schedulerFee();
        vm.deal(ALICE, fee);
        vm.prank(ALICE);
        uint256 id = flap.triggerConversion{value: fee}();
        vm.prank(TRIGGER);
        flap.trigger(id);

        assertGt(flap.rewardPool(), outD, "the scheduled path did not credit the same pool");
        assertTrue(flap.solvent());
    }

    /// @notice The scheduler's fee is not tax and must never be converted as if it were.
    /// @dev The fee arrives in this balance before the amount is sized, so the first version of
    ///      the derived sizing counted it: a 0.05 window reserved 0.0502. That is somebody's fee
    ///      turned into bounty, and it also reserves more than the window produced.
    function test_TheSchedulerFeeIsNotConvertedAsTax() public {
        _tax(0.05 ether);
        uint256 fee = flap.schedulerFee();
        vm.deal(ALICE, fee);

        vm.prank(ALICE);
        uint256 id = flap.triggerConversion{value: fee}();

        (uint128 amount,) = flap.scheduled(id);
        assertEq(uint256(amount), 0.05 ether, "the fee was converted along with the tax");
        assertEq(flap.reserved(), 0.05 ether, "the fee was reserved as tax");
    }

    /// @notice Executing one conversion arms the next, so the cadence needs nobody to remember it.
    /// @dev The Trigger Service has no recurrence of its own — its documentation says a requester
    ///      schedules the next trigger from inside the callback — so this is the whole of the
    ///      automation. Removing it broke no test until this one existed, which is why it does.
    function test_ExecutingAConversionArmsTheNextEpoch() public {
        _tax(0.05 ether);
        uint256 fee = flap.schedulerFee();
        vm.deal(ALICE, fee);
        vm.prank(ALICE);
        uint256 first = flap.triggerConversion{value: fee}();

        // More tax arrives while the first conversion is in flight, and the vault keeps enough to
        // pay for arming the next one.
        _tax(0.05 ether);
        vm.recordLogs();
        vm.prank(TRIGGER);
        flap.trigger(first);

        // A second ConversionScheduled inside the callback is the next epoch being armed.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 wanted = keccak256("ConversionScheduled(uint256,uint256,uint256)");
        uint256 armed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(flap) && logs[i].topics[0] == wanted) ++armed;
        }
        assertGt(armed, 0, "executing a conversion did not arm the next epoch");
        assertGt(flap.rewardPool(), 0, "the conversion itself did not land");
    }

    /// And a window with nothing left to convert simply stops arming, rather than reverting the
    /// conversion that already happened.
    function test_AnEmptyWindowStopsArmingWithoutUndoingTheConversion() public {
        _tax(0.05 ether);
        uint256 fee = flap.schedulerFee();
        vm.deal(ALICE, fee);
        vm.prank(ALICE);
        uint256 id = flap.triggerConversion{value: fee}();

        // No further tax: there is nothing for the next epoch to take.
        vm.prank(TRIGGER);
        flap.trigger(id);

        assertGt(flap.rewardPool(), 0, "the conversion was undone by the failed arming");
        assertEq(flap.reserved(), 0, "a reservation survived an epoch that armed nothing");
    }

    /// @notice A window too small to be worth its own fee is not converted at the vault's expense.
    /// @dev The self-arming path pays the scheduler out of the vault's balance, which is tax. At
    ///      one epoch every five minutes that is 288 fees a day, so a vault nobody is trading
    ///      against would spend more converting than it converted. A thin window waits and rolls
    ///      into the next one instead.
    function test_AWindowWorthLessThanItsFeeIsNotArmed() public {
        _tax(0.05 ether);
        uint256 fee = flap.schedulerFee();
        vm.deal(ALICE, fee);
        vm.prank(ALICE);
        uint256 id = flap.triggerConversion{value: fee}();

        // A dust window arrives before the first conversion executes: below the cover multiple.
        _tax(fee);

        vm.recordLogs();
        vm.prank(TRIGGER);
        flap.trigger(id);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 wanted = keccak256("ConversionScheduled(uint256,uint256,uint256)");
        uint256 armed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(flap) && logs[i].topics[0] == wanted) ++armed;
        }
        assertEq(armed, 0, "the vault paid a fee to convert less than the fee");
        assertGt(flap.rewardPool(), 0, "the conversion itself did not land");
    }
}
