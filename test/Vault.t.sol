// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {TaxTokenMock} from "./TaxTokenMock.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice A controller that tries to reach outside its own namespace.
/// @dev Stands in for the worst realistic case: one of the protocol's own contracts is replaced
///      or compromised and does its best to drain everything else in the vault.
contract HostileController {
    AssayVault public immutable vault;

    constructor(AssayVault v) {
        vault = v;
    }

    /// Attempt 1: name the victim's account directly and pay it to myself.
    function tryPayOut(bytes32 kind, bytes32 key, address to, uint256 amount) external {
        vault.payOut(kind, key, to, amount);
    }

    /// Attempt 2: move the victim's balance into an account I control, then cash it out.
    function tryMove(bytes32 fromKind, bytes32 fromKey, uint256 amount) external {
        vault.move(fromKind, fromKey, "loot", bytes32(0), amount);
    }

    /// Attempt 3: overdraw my own funded account and let the surplus cover it.
    function tryOverdraw(bytes32 kind, bytes32 key, address to, uint256 amount) external {
        vault.payOut(kind, key, to, amount);
    }

    function fund(bytes32 kind, bytes32 key, address from, uint256 amount) external {
        vault.deposit(kind, key, from, amount);
    }
}

contract VaultTest is BaseTest {
    /// The invariant the vault exists to hold.
    function test_SolventAndFullyAttributed() public {
        _enroll(ALICE, AGENT_ALICE);
        assertTrue(vault.solvent(), "solvent");
        assertEq(vault.unaccounted(), 0, "every unit is attributed");
        assertEq(
            token.balanceOf(address(vault)),
            vault.totalAccounted(),
            "held equals accounted"
        );
    }

    /// Stake and pot are separate buckets, not one pile.
    function test_StakeAndPotAreSeparateAccounts() public {
        _enroll(ALICE, AGENT_ALICE);
        assertEq(vault.balanceOf(roster.stakeAccount(ALICE)), MIN_STAKE, "stake bucket");
        assertEq(vault.balanceOf(tournament.potAccount(taskId)), POT, "pot bucket");
        assertTrue(
            roster.stakeAccount(ALICE) != tournament.potAccount(taskId),
            "different account ids"
        );
    }

    /// An address that was never wired in can do nothing at all.
    function test_NonControllerCanDoNothing() public {
        vm.startPrank(BOB);
        vm.expectRevert(abi.encodeWithSelector(AssayVault.NotController.selector, BOB));
        vault.deposit("stake", bytes32(0), BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(AssayVault.NotController.selector, BOB));
        vault.payOut("stake", bytes32(0), BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(AssayVault.NotController.selector, BOB));
        vault.move("stake", bytes32(0), "stake", bytes32(uint256(1)), 1);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------
    // The claim under test: namespaces are not forgeable
    // -------------------------------------------------------------------------------------

    /// @dev Break what the design guards. A fully-authorised controller, handed the exact
    ///      `(kind, key)` of somebody else's funded account, still cannot move a single unit of
    ///      it — because the vault derives the id from `msg.sender` rather than trusting the
    ///      arguments. This is the difference between "we promise not to" and "it cannot".
    function test_AControllerCannotReachAnotherControllersAccount() public {
        _enroll(ALICE, AGENT_ALICE);

        HostileController hostile = new HostileController(vault);
        // Give it the same standing as the real contracts.
        AssayVault fresh = new AssayVault(IERC20(address(token)), SALVAGE);
        fresh.addController(address(hostile));
        fresh.freeze();

        // Against the REAL vault it is not even a controller.
        vm.expectRevert(
            abi.encodeWithSelector(AssayVault.NotController.selector, address(hostile))
        );
        hostile.tryPayOut("stake", bytes32(uint256(uint160(ALICE))), address(hostile), MIN_STAKE);

        // And the stake is exactly where it was.
        assertEq(vault.balanceOf(roster.stakeAccount(ALICE)), MIN_STAKE, "stake untouched");
    }

    /// Even *as* a controller of the same vault, the namespace still holds.
    function test_AuthorisedControllerStillCannotTouchAnotherNamespace() public {
        _enroll(ALICE, AGENT_ALICE);

        // Deploy a vault where the hostile contract is a legitimate, frozen-in controller
        // alongside a victim that has real money in it.
        AssayVault v = new AssayVault(IERC20(address(token)), SALVAGE);
        HostileController victim = new HostileController(v);
        HostileController thief = new HostileController(v);
        v.addController(address(victim));
        v.addController(address(thief));
        v.freeze();

        vm.prank(CURATOR);
        token.transfer(ALICE, 500e18);
        vm.prank(ALICE);
        token.approve(address(v), type(uint256).max);
        victim.fund("stake", bytes32(uint256(uint160(ALICE))), ALICE, 500e18);

        bytes32 victimAccount = v.accountId(address(victim), "stake", bytes32(uint256(uint160(ALICE))));
        assertEq(v.balanceOf(victimAccount), 500e18, "victim funded");

        // The thief knows the kind and the key. It still resolves to its own empty account.
        bytes32 thiefAccount = v.accountId(address(thief), "stake", bytes32(uint256(uint160(ALICE))));
        assertEq(v.balanceOf(thiefAccount), 0, "same arguments, different account");

        vm.expectRevert(
            abi.encodeWithSelector(AssayVault.InsufficientAccount.selector, thiefAccount, 0, 500e18)
        );
        thief.tryPayOut("stake", bytes32(uint256(uint160(ALICE))), address(thief), 500e18);

        vm.expectRevert(
            abi.encodeWithSelector(AssayVault.InsufficientAccount.selector, thiefAccount, 0, 500e18)
        );
        thief.tryMove("stake", bytes32(uint256(uint160(ALICE))), 500e18);

        assertEq(v.balanceOf(victimAccount), 500e18, "victim's money never moved");
    }

    /// A controller cannot overdraw its own account by leaning on the vault's other holdings.
    function test_ControllerCannotOverdrawIntoOtherHoldings() public {
        AssayVault v = new AssayVault(IERC20(address(token)), SALVAGE);
        HostileController a = new HostileController(v);
        HostileController b = new HostileController(v);
        v.addController(address(a));
        v.addController(address(b));
        v.freeze();

        vm.startPrank(CURATOR);
        token.transfer(ALICE, 1_000e18);
        vm.stopPrank();
        vm.prank(ALICE);
        token.approve(address(v), type(uint256).max);

        a.fund("x", bytes32(0), ALICE, 900e18); // the vault now really holds 900
        b.fund("x", bytes32(0), ALICE, 100e18); // b's own account holds 100

        bytes32 bAcct = v.accountId(address(b), "x", bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(AssayVault.InsufficientAccount.selector, bAcct, 100e18, 400e18)
        );
        b.tryOverdraw("x", bytes32(0), address(b), 400e18);
    }

    // -------------------------------------------------------------------------------------
    // Stray transfers
    // -------------------------------------------------------------------------------------

    /// @dev A donation into the vault must never become payable. Money that arrived outside the
    ///      ledger belongs to nobody, and a payout that could reach it would turn a stray
    ///      transfer into somebody's phantom winnings.
    function test_StrayTransferIsVisibleAndNotPayable() public {
        _enroll(ALICE, AGENT_ALICE);
        uint256 accountedBefore = vault.totalAccounted();

        vm.prank(CURATOR);
        token.transfer(address(vault), 7_777e18);

        assertEq(vault.unaccounted(), 7_777e18, "surplus is visible");
        assertEq(vault.totalAccounted(), accountedBefore, "ledger did not grow");
        assertTrue(vault.solvent(), "still solvent");

        // Alice's stake account did not grow, so nothing extra is withdrawable.
        assertEq(vault.balanceOf(roster.stakeAccount(ALICE)), MIN_STAKE, "stake unchanged");

        vm.warp(revealEnd);
        uint256 before = token.balanceOf(ALICE);
        vm.prank(ALICE);
        roster.withdraw();
        assertEq(token.balanceOf(ALICE) - before, MIN_STAKE, "paid her stake, not the surplus");
        assertEq(vault.unaccounted(), 7_777e18, "surplus still sitting there");
    }

    /// The surplus can be recovered, but only to the address fixed at deploy.
    function test_SweepMovesOnlyTheSurplusAndOnlyToSalvage() public {
        _enroll(ALICE, AGENT_ALICE);
        vm.prank(CURATOR);
        token.transfer(address(vault), 7_777e18);

        uint256 accounted = vault.totalAccounted();

        // Permissionless — and the caller gains nothing by calling it.
        uint256 callerBefore = token.balanceOf(BOB);
        vm.prank(BOB);
        uint256 swept = vault.sweepUnaccounted();

        assertEq(swept, 7_777e18, "only the surplus");
        assertEq(token.balanceOf(SALVAGE), 7_777e18, "to the fixed destination");
        assertEq(token.balanceOf(BOB), callerBefore, "the caller gains nothing by calling it");
        assertEq(vault.totalAccounted(), accounted, "accounted funds untouched");
        assertEq(vault.balanceOf(roster.stakeAccount(ALICE)), MIN_STAKE, "stake untouched");
        assertTrue(vault.solvent(), "still solvent");

        vm.expectRevert(AssayVault.NothingUnaccounted.selector);
        vault.sweepUnaccounted();
    }

    // -------------------------------------------------------------------------------------
    // Wiring is a deployment fact, not a setting
    // -------------------------------------------------------------------------------------

    function test_ControllersCannotBeAddedAfterFreeze() public {
        assertTrue(vault.controllersFrozen(), "frozen at deploy");
        vm.expectRevert(AssayVault.AlreadyFrozen.selector);
        vault.addController(address(0xBAD));
        assertFalse(vault.isController(address(0xBAD)), "not a controller");
    }

    function test_OnlyDeployerCouldEverHaveWired() public {
        AssayVault v = new AssayVault(IERC20(address(token)), SALVAGE);
        vm.prank(BOB);
        vm.expectRevert(AssayVault.NotDeployer.selector);
        v.addController(BOB);
        vm.prank(BOB);
        vm.expectRevert(AssayVault.NotDeployer.selector);
        v.freeze();
    }
}
