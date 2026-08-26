// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AssayToken} from "../src/AssayToken.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice A perfectly ordinary foreign token. Nothing in the vault ledger can denominate it.
contract StrayToken is ERC20 {
    constructor(address to, uint256 amount) ERC20("Stray", "STRAY") {
        _mint(to, amount);
    }
}

/// @notice A token with two entry points onto one balance — the shape that has drained real
///         vaults. `SharedLedger` is the accounted `asset`; `AliasEntry` is a *different address*
///         whose `transfer` moves the caller's balance in that same ledger.
/// @dev This is not a token that steals from an allowance. It is the real thing: one balance
///      mapping, two addresses that can spend it. The vault's `token == asset` comparison cannot
///      see it, which is the entire point.
contract SharedLedger is ERC20 {
    address public aliasEntry;

    constructor(address to, uint256 amount) ERC20("Shared", "SHARE") {
        _mint(to, amount);
    }

    function setAlias(address aliasEntry_) external {
        aliasEntry = aliasEntry_;
    }

    /// @dev The second door. Same balances, different address.
    function aliasTransfer(address from, address to, uint256 amount) external {
        require(msg.sender == aliasEntry, "not the alias");
        _transfer(from, to, amount);
    }
}

contract AliasEntry {
    SharedLedger public immutable underlying;
    uint256 public bite;

    constructor(SharedLedger underlying_) {
        underlying = underlying_;
    }

    function setBite(uint256 bite_) external {
        bite = bite_;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1;
    }

    /// @dev `msg.sender` here is the vault, so this spends the *vault's* accounted balance.
    function transfer(address to, uint256) external returns (bool) {
        if (bite != 0) underlying.aliasTransfer(msg.sender, to, bite);
        return true;
    }
}

/// @notice A token whose `transfer` hands control back to the vault mid-sweep.
contract ReenteringToken is ERC20 {
    AssayVault public immutable vault;
    bool private armed = true;

    constructor(AssayVault vault_) ERC20("Reenter", "RE") {
        vault = vault_;
        _mint(msg.sender, 1_000e18);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from == address(vault)) {
            armed = false;
            vault.sweepToken(IERC20(address(this)));
        }
    }
}

/// @notice A salvage destination that refuses native value.
contract RejectingSalvage {}

contract VaultSweepTest is BaseTest {
    // ---------------------------------------------------------------------------------
    // A foreign token is sweepable in full, because none of it can ever be accounted
    // ---------------------------------------------------------------------------------

    function test_ForeignTokenSweepsInFullAndLeavesTheLedgerAlone() public {
        _enroll(ALICE, AGENT_ALICE);
        uint256 accounted = vault.totalAccounted();
        uint256 assetHeld = token.balanceOf(address(vault));

        StrayToken stray = new StrayToken(address(vault), 500e18);
        assertEq(vault.sweepable(IERC20(address(stray))), 500e18, "the whole balance is sweepable");

        vm.prank(BOB);
        uint256 swept = vault.sweepToken(IERC20(address(stray)));

        assertEq(swept, 500e18, "all of it moved");
        assertEq(stray.balanceOf(SALVAGE), 500e18, "to the fixed destination");
        assertEq(stray.balanceOf(BOB), 0, "the caller kept nothing");
        assertEq(stray.balanceOf(address(vault)), 0, "nothing stranded");
        assertEq(vault.totalAccounted(), accounted, "ledger untouched");
        assertEq(token.balanceOf(address(vault)), assetHeld, "asset untouched");
        assertTrue(vault.solvent(), "still solvent");
    }

    /// The old gap, stated as a test: before the fix this token could never leave.
    function test_ForeignTokenIsNoLongerStranded() public {
        StrayToken stray = new StrayToken(address(vault), 1e18);
        vm.prank(BOB);
        vault.sweepToken(IERC20(address(stray)));
        assertEq(stray.balanceOf(address(vault)), 0, "recoverable, not stranded forever");
    }

    // ---------------------------------------------------------------------------------
    // The accounted asset keeps exactly its old, surplus-only rule
    // ---------------------------------------------------------------------------------

    function testFuzz_SweepingTheAssetNeverReachesAccountedFunds(uint96 donation) public {
        _enroll(ALICE, AGENT_ALICE);
        uint256 accounted = vault.totalAccounted();
        donation = uint96(bound(donation, 1, token.balanceOf(CURATOR)));

        vm.prank(CURATOR);
        token.transfer(address(vault), donation);

        vm.prank(BOB);
        uint256 swept = vault.sweepToken(IERC20(address(token)));

        assertEq(swept, donation, "exactly the surplus, whatever its size");
        assertEq(token.balanceOf(address(vault)), accounted, "balance falls to the ledger, never below");
        assertEq(vault.totalAccounted(), accounted, "ledger unchanged");
        assertTrue(vault.solvent(), "solvent");
    }

    /// Naming the asset at the wide entry point is not a wider power.
    function test_SweepTokenOnAssetEqualsSweepUnaccounted() public {
        _enroll(ALICE, AGENT_ALICE);
        vm.prank(CURATOR);
        token.transfer(address(vault), 1_000e18);

        uint256 snap = vm.snapshotState();
        vm.prank(BOB);
        uint256 viaWide = vault.sweepToken(IERC20(address(token)));
        uint256 leftWide = token.balanceOf(address(vault));
        vm.revertToState(snap);

        vm.prank(BOB);
        uint256 viaNarrow = vault.sweepUnaccounted();
        assertEq(viaWide, viaNarrow, "same amount");
        assertEq(leftWide, token.balanceOf(address(vault)), "same residue");
    }

    function test_SweepingAnEmptyForeignTokenReverts() public {
        StrayToken stray = new StrayToken(address(this), 1e18);
        vm.expectRevert(AssayVault.NothingUnaccounted.selector);
        vault.sweepToken(IERC20(address(stray)));
    }

    function test_ZeroTokenIsRejected() public {
        vm.expectRevert(AssayVault.ZeroAddress.selector);
        vault.sweepToken(IERC20(address(0)));
    }

    // ---------------------------------------------------------------------------------
    // The alias case: the address comparison misses it, the post-condition catches it
    // ---------------------------------------------------------------------------------

    /// @dev A standalone vault whose asset is the shared-ledger token, and a real deposit in it,
    ///      so there is something to steal and the theft is the genuine article.
    function _aliasFixture() internal returns (AssayVault v, SharedLedger t, AliasEntry door) {
        t = new SharedLedger(address(this), 1_000e18);
        v = new AssayVault(IERC20(address(t)), SALVAGE);
        v.addController(address(this));
        v.freeze();
        t.approve(address(v), type(uint256).max);
        v.deposit(bytes32("stake"), bytes32("alice"), address(this), 400e18);

        door = new AliasEntry(t);
        t.setAlias(address(door));
        assertTrue(address(door) != address(t), "the address comparison lets it through");
        assertEq(v.totalAccounted(), 400e18, "there is something to steal");
    }

    /// Proven red at one wei: everything except the measurement admits this token.
    function test_AliasTokenCannotDrainAccountedFundsByOneWei() public {
        (AssayVault v, SharedLedger t, AliasEntry door) = _aliasFixture();

        door.setBite(1);
        vm.prank(BOB);
        vm.expectRevert(AssayVault.SweepTouchedAsset.selector);
        v.sweepToken(IERC20(address(door)));

        assertEq(t.balanceOf(address(v)), 400e18, "not one wei left");
        assertTrue(v.solvent(), "solvent");
    }

    /// The whole ledger, same result.
    function test_AliasTokenCannotDrainTheWholeLedger() public {
        (AssayVault v, SharedLedger t, AliasEntry door) = _aliasFixture();

        door.setBite(400e18);
        vm.prank(BOB);
        vm.expectRevert(AssayVault.SweepTouchedAsset.selector);
        v.sweepToken(IERC20(address(door)));

        assertEq(t.balanceOf(address(v)), 400e18, "accounted funds still here");
        assertEq(v.balanceOf(v.accountId(address(this), bytes32("stake"), bytes32("alice"))), 400e18);
    }

    /// The same token with a zero bite sails through the identical call path, which is what makes
    /// the two tests above a gate rather than an accident of the fixture.
    function test_TheGuardIsWhatFiresNotTheFixture() public {
        (AssayVault v,, AliasEntry door) = _aliasFixture();
        door.setBite(0);
        vm.prank(BOB);
        uint256 swept = v.sweepToken(IERC20(address(door)));
        assertEq(swept, 1, "no revert; only the bite differs");
    }

    // ---------------------------------------------------------------------------------
    // Re-entry through the one call the caller gets to choose
    // ---------------------------------------------------------------------------------

    function test_HostileTokenCannotReenterTheSweep() public {
        ReenteringToken evil = new ReenteringToken(vault);
        evil.transfer(address(vault), 100e18);

        vm.prank(BOB);
        vm.expectRevert(AssayVault.SweepReentered.selector);
        vault.sweepToken(IERC20(address(evil)));
    }

    // ---------------------------------------------------------------------------------
    // Native value
    // ---------------------------------------------------------------------------------

    function test_VaultStillRefusesAPlainNativeTransfer() public {
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok, "no receive: the mistake is prevented, not merely recoverable");
    }

    function test_ForceFedNativeValueIsRecoverable() public {
        // The delivery no contract can decline.
        vm.deal(address(vault), 3 ether);
        assertEq(vault.sweepableNative(), 3 ether, "all of it is unaccounted");

        uint256 salvageBefore = SALVAGE.balance;
        vm.prank(BOB);
        uint256 swept = vault.sweepNative();

        assertEq(swept, 3 ether, "all of it moved");
        assertEq(SALVAGE.balance - salvageBefore, 3 ether, "to the fixed destination");
        assertEq(BOB.balance, 0, "the caller kept nothing");
        assertEq(address(vault).balance, 0, "nothing stranded");
    }

    function test_NativeSweepWithNothingToSweepReverts() public {
        vm.expectRevert(AssayVault.NothingUnaccounted.selector);
        vault.sweepNative();
    }

    function test_ARejectingSalvageStrandsNativeValueLoudly() public {
        AssayToken t = new AssayToken(address(this));
        AssayVault v = new AssayVault(IERC20(address(t)), address(new RejectingSalvage()));
        vm.deal(address(v), 1 ether);
        vm.expectRevert(AssayVault.NativeSweepFailed.selector);
        v.sweepNative();
    }

    // ---------------------------------------------------------------------------------
    // The caller is still nobody
    // ---------------------------------------------------------------------------------

    function testFuzz_AnyCallerAndOnlySalvageIsPaid(address caller) public {
        vm.assume(caller != SALVAGE && caller != address(0) && caller != address(vault));
        StrayToken stray = new StrayToken(address(vault), 42e18);

        vm.prank(caller);
        vault.sweepToken(IERC20(address(stray)));

        assertEq(stray.balanceOf(caller), 0, "no caller can route it to themselves");
        assertEq(stray.balanceOf(SALVAGE), 42e18, "it goes where the deployment said");
    }

    function test_NoPrivilegedRoleExists() public view {
        // The three sweeps are the only new external functions, and none of them reads a role.
        assertTrue(vault.controllersFrozen(), "controller set is a deployment fact");
        assertEq(vault.salvage(), SALVAGE, "destination is immutable");
    }
}
