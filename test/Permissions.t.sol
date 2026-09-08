// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Stack} from "../script/Stack.sol" ;
import {Guardians} from "./Guardians.sol";

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
///      it had lost. It cannot be wrong a third time: the vault names no curator at all now. The
///      address this file calls CURATOR is the TOURNAMENT's curator, who may post on the curated
///      lane and is nothing whatever to this contract — which is exactly what the tests below
///      assert, one refused call at a time.
///
///      Comments cannot be executed, so they drift silently. This file is the version that cannot:
///      when a permission moves, the assertion here fails, and whoever moved it has to come and
///      look at the sentence they are contradicting. It is not extra coverage of the guards — each
///      has its own test where it lives — it is a single place where the whole matrix is written
///      down in a form that runs.
contract PermissionsTest is BaseTest {
    address internal constant STRANGER = address(0xBEEF);
    address internal constant BTCB = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8;
    address internal constant TRIGGER = 0x560E9830926C9e0EB98a59c6b9902383Fc0D9Eb2;

    AssayFlapVault internal flap;
    address internal guardian;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        flap = Stack.newFlapVault(Guardians.TESTNET, tournament, address(token), Stack.newPriceGuard(Guardians.TESTNET));
        guardian = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    }

    // --------------------------------------------------- the tournament's curator holds nothing

    /// @dev Not a destination either, since the withdrawal that paid one was removed. The vault
    ///      stores no curator, so this account is a stranger to it with a familiar name.
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

    // ------------------------------------------------------- and this one is open to nobody

    /// @notice Idle tax has no way out to a non-miner except the Guardian's hatch. Not the
    ///         curator's, not a stranger's, and not the Guardian's by any other route.
    /// @dev `withdrawUnconverted(uint256)` used to pay the vault's own curator, and both are gone —
    ///      the function and the stored address. What replaces the old "who may call it" assertion
    ///      is the strongest form of it: there is no such call. The vault has no `fallback`, so a
    ///      call carrying a selector it does not implement reverts for every caller, and the
    ///      balance is still there afterwards to prove nothing leaked on the way.
    ///
    ///      Asserted by selector rather than by compiling the call, because the compiler will not
    ///      let this file name a function that does not exist — and a test that cannot be written
    ///      is not the same as a test that passes.
    function test_NobodyMayTakeIdleTaxOutOfTheVault() public {
        vm.deal(address(flap), 0.02 ether);
        vm.warp(uint256(revealEnd) + 1);

        uint256 curatorBefore = CURATOR.balance;
        uint256 strangerBefore = STRANGER.balance;

        bytes memory gone = abi.encodeWithSignature("withdrawUnconverted(uint256)", uint256(0));
        address[3] memory callers = [STRANGER, CURATOR, guardian];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            (bool ok,) = address(flap).call(gone);
            assertFalse(ok, "the withdrawal is still reachable");
        }

        assertEq(address(flap).balance, 0.02 ether, "the tax did not stay in the vault");
        assertEq(CURATOR.balance, curatorBefore, "the tax reached the curator");
        assertEq(STRANGER.balance, strangerBefore, "the tax reached the caller");
    }

    /// @dev The conversion is the call that is open to anyone now, and what makes leaving it open
    ///      safe is the same property the withdrawal used to need: the caller cannot name where the
    ///      proceeds go. They pay a fee, the scheduler executes at a moment they did not pick, and
    ///      the BTCB lands in the pool — which pays the drawn task, and from there only miners the
    ///      tournament scored.
    function test_TheCallerOfAConversionCannotDirectAWeiOfIt() public {
        vm.deal(address(flap), 0.05 ether);
        uint256 fee = flap.schedulerFee();
        uint256 strangerBtcb = IERC20(BTCB).balanceOf(STRANGER);
        uint256 curatorBtcb = IERC20(BTCB).balanceOf(CURATOR);
        // Dealt exactly the fee, so any BNB they hold afterwards came out of the vault.
        vm.deal(STRANGER, fee);

        vm.prank(STRANGER);
        uint256 id = flap.triggerConversion{value: fee}();
        assertGt(id, 0, "nothing was armed, so this asserts nothing");

        vm.prank(TRIGGER);
        flap.trigger(id);

        assertGt(flap.rewardPool(), 0, "the conversion did not reach the pool");
        assertEq(IERC20(BTCB).balanceOf(STRANGER), strangerBtcb, "the caller took the proceeds");
        assertEq(IERC20(BTCB).balanceOf(CURATOR), curatorBtcb, "the proceeds reached the curator");
        assertEq(STRANGER.balance, 0, "the caller was paid out of the tax");
        assertTrue(flap.solvent(), "the ledger no longer covers what it claims");
    }
}
