// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";

/// @notice One executable statement of who may do what.
///
/// @dev Three separate audit rounds have raised the same class of defect: a sentence saying who may
///      call something, contradicted by the `require` that decides it. Every time, the permission
///      had moved in an earlier round and the prose had not followed. The `curator` NatSpec was
///      wrong twice, in opposite directions — first claiming a right it never had, then keeping one
///      it had lost.
///
///      Comments cannot be executed, so they drift silently. This file is the version that cannot:
///      when a permission moves, the assertion here fails, and whoever moved it has to come and
///      look at the sentence they are contradicting. It is not extra coverage of the guards — each
///      has its own test where it lives — it is a single place where the whole matrix is written
///      down in a form that runs.
contract PermissionsTest is BaseTest {
    address internal constant STRANGER = address(0xBEEF);

    AssayFlapVault internal flap;
    address internal guardian;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        flap = new AssayFlapVault(tournament, address(token), CURATOR, new PriceGuard());
        guardian = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    }

    // ------------------------------------------------------------------ the curator holds nothing

    /// @dev The curator is a destination, not a role. It is where `withdrawUnconverted` pays, and
    ///      that is the whole of it — which is exactly what its NatSpec now says.
    function test_TheCuratorMayNotEndow() public {
        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Only the guardian / 仅限守护者"));
        flap.endow(1 ether, 1);
    }

    function test_TheCuratorMayNotCancelALiveConversion() public {
        vm.deal(address(flap), 0.05 ether);
        uint256 fee = flap.schedulerFee();
        vm.deal(STRANGER, fee);
        vm.prank(STRANGER);
        uint256 id = flap.triggerConversion{value: fee}();
        assertGt(id, 0, "nothing was armed, so this asserts nothing");

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Not cancellable yet / 尚不可取消"));
        flap.cancelConversion(id);
    }

    function test_TheCuratorMayNotWithdrawFromTheVaultDirectly() public {
        vm.deal(address(flap), 1 ether);
        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Only the guardian / 仅限守护者"));
        flap.emergencyWithdrawNative(CURATOR);
    }

    // ------------------------------------------------------------------ the Guardian holds these

    function test_TheGuardianMayCancelAtAnyTime() public {
        vm.deal(address(flap), 0.05 ether);
        uint256 fee = flap.schedulerFee();
        vm.deal(STRANGER, fee);
        vm.prank(STRANGER);
        uint256 id = flap.triggerConversion{value: fee}();

        vm.prank(guardian);
        flap.cancelConversion(id);
        (uint96 left,,) = flap.scheduled(id);
        assertEq(left, 0, "the Guardian could not cancel");
    }

    function test_OnlyTheGuardianMayEmergencyWithdraw() public {
        vm.deal(address(flap), 1 ether);

        vm.prank(STRANGER);
        vm.expectRevert(bytes(unicode"Only the guardian / 仅限守护者"));
        flap.emergencyWithdrawNative(STRANGER);

        // Paid to a plain address, not to the Guardian itself: Flap's Guardian is a contract and
        // need not accept native coin. What this pins is who may CALL it, not who receives.
        address rescue = makeAddr("rescue");
        vm.prank(guardian);
        flap.emergencyWithdrawNative(rescue);
        assertEq(rescue.balance, 1 ether, "the Guardian could not rescue");
    }

    // ------------------------------------------------------------------ these are open to anyone

    /// @dev Permissionless on purpose: none of them takes a decision, and each is something the
    ///      project stalling must not be able to prevent.
    function test_AStrangerMaySchedule() public {
        vm.deal(address(flap), 0.05 ether);
        uint256 fee = flap.schedulerFee();
        vm.deal(STRANGER, fee);
        vm.prank(STRANGER);
        assertGt(flap.triggerConversion{value: fee}(), 0, "a stranger could not schedule");
    }

    function test_AStrangerMayWithdrawUnconvertedToTheCurator() public {
        vm.deal(address(flap), 0.02 ether);
        vm.warp(uint256(revealEnd) + 1);

        uint256 before = CURATOR.balance;
        vm.prank(STRANGER);
        uint256 sent = flap.withdrawUnconverted(0);
        assertGt(sent, 0, "a stranger could not trigger the withdrawal");
        assertEq(CURATOR.balance - before, sent, "it did not pay the curator");
    }

    /// @dev And the destination is not the caller's to choose, which is what makes the call safe to
    ///      leave open.
    function test_TheWithdrawalAlwaysPaysTheCuratorAndNobodyElse() public {
        vm.deal(address(flap), 0.02 ether);
        vm.warp(uint256(revealEnd) + 1);

        uint256 strangerBefore = STRANGER.balance;
        vm.prank(STRANGER);
        flap.withdrawUnconverted(0);
        assertEq(STRANGER.balance, strangerBefore, "the caller paid themselves");
    }
}
