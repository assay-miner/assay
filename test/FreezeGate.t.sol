// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AssayToken} from "../src/AssayToken.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice A forge broadcast is N transactions, so `addController` and `freeze()` land in
///         different blocks. These tests pin down what a controller may do inside that gap.
contract FreezeGateTest is Test {
    address internal constant CURATOR = address(0xC0);
    address internal constant SALVAGE = address(0x5A);
    address internal constant VICTIM = address(0x71C);
    address internal constant ATTACKER = address(0xBAD);

    bytes32 internal constant KIND = bytes32("STAKE");

    AssayToken internal token;
    AssayVault internal vault;

    function setUp() public {
        vm.prank(CURATOR);
        token = new AssayToken(CURATOR);
        vault = new AssayVault(IERC20(address(token)), SALVAGE);

        // A standing allowance is what makes the gap worth attacking. Anyone who has ever
        // approved this vault is reachable by whoever holds a controller slot.
        vm.prank(CURATOR);
        token.transfer(VICTIM, 500e18);
        vm.prank(VICTIM);
        token.approve(address(vault), type(uint256).max);
    }

    /// @notice The gap is unusable, not merely unused: a controller named before the seal
    ///         cannot pull a victim's standing allowance, because value cannot move at all yet.
    function test_ControllerNamedBeforeTheSealCannotPullAVictimsAllowance() public {
        vault.addController(ATTACKER);

        vm.prank(ATTACKER);
        vm.expectRevert(AssayVault.NotFrozen.selector);
        vault.deposit(KIND, bytes32(uint256(uint160(ATTACKER))), VICTIM, 500e18);

        assertEq(token.balanceOf(VICTIM), 500e18, "victim untouched");
        assertEq(token.balanceOf(address(vault)), 0, "vault took nothing");
        assertEq(vault.totalAccounted(), 0, "ledger credited nothing");
    }

    /// @notice Every value-moving entry point is behind the same seal, not just `deposit`.
    ///         A gate installed at one call site and missed at the second is the usual shape.
    function test_EveryValuePathIsSealed() public {
        vault.addController(ATTACKER);
        vm.startPrank(ATTACKER);

        vm.expectRevert(AssayVault.NotFrozen.selector);
        vault.deposit(KIND, bytes32(0), VICTIM, 1);

        vm.expectRevert(AssayVault.NotFrozen.selector);
        vault.move(KIND, bytes32(0), KIND, bytes32(uint256(1)), 1);

        vm.expectRevert(AssayVault.NotFrozen.selector);
        vault.payOut(KIND, bytes32(0), ATTACKER, 1);

        vm.stopPrank();
    }

    /// @notice The seal opens the contract for business rather than closing it; this is the
    ///         control that proves the gate is not simply bricking the vault.
    function test_AfterTheSealTheSamePathWorks() public {
        vault.addController(ATTACKER);
        vault.freeze();

        vm.prank(ATTACKER);
        vault.deposit(KIND, bytes32(uint256(uint160(VICTIM))), VICTIM, 500e18);

        assertEq(vault.totalAccounted(), 500e18, "credited after the seal");
        assertEq(token.balanceOf(address(vault)), 500e18, "and actually held");
    }
}
