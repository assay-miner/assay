// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapFactory} from "../src/AssayFlapFactory.sol";
import {VaultUISchema, VaultDataSchema, FieldDescriptor} from "../src/flap/IVaultSchemasV1.sol";

/// @notice The coverage Flap's own spec checker asks for, written against its rules.
///
/// @dev Rule 006 lists what an integration suite must cover before submission: the `receive()`
///      gas budget, both sides of every critical write, the views a UI reads, `description()`,
///      `vaultUISchema()`, `vaultDataSchema()`, `newVault()`'s portal guard, and Guardian access
///      to every privileged function. Those are separate concerns from the economics, which
///      RewardAsset.t.sol covers, so they live in their own file rather than being folded into
///      tests that already have a different subject.
contract FlapSpecTest is BaseTest {
    address internal constant BTCB = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8;
    address internal constant TAXPAYER = address(0x7A);
    /// @dev Where the escape hatch sends to. Not the Guardian's own address: on chain 97 that is
    ///      a contract that will not take a plain native transfer, which is exactly why the spec
    ///      has the caller name the destination instead of hardcoding one.
    address internal constant SAFE = address(0x5AFE);

    AssayFlapVault internal flap;
    AssayFlapFactory internal factory;
    address internal guardian;
    address internal portal;

    function setUp() public override {
        // Chain 97: the guardian, the portal and the reward venue all have to be the real ones,
        // and the vault refuses to exist anywhere they are not.
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        flap = new AssayFlapVault(tournament, address(token), CURATOR, new PriceGuard());
        factory = new AssayFlapFactory(tournament, new PriceGuard());
        guardian = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        portal = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
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

    /// @dev The floor an operator would actually pass: one percent under the pool's own price.
    ///      Zero is no longer accepted, and it should not have been — a privileged caller who
    ///      may declare any price acceptable can sandwich the vault's own conversion.
    function _floor(uint256 bnbAmount) internal view returns (uint256) {
        return (flap.quote(bnbAmount) * 99) / 100;
    }

    // ---------------------------------------------------------------- Rule 005

    /// @notice Tax revenue arrives through `receive()`, so a costly one breaks tax collection
    ///         for the token permanently. The protocol's ceiling is 1,000,000.
    function test_ReceiveStaysWellUnderTheGasCeiling() public {
        vm.deal(TAXPAYER, 10 ether);
        vm.prank(TAXPAYER);
        uint256 before = gasleft();
        (bool ok,) = payable(address(flap)).call{value: 1 ether}("");
        uint256 used = before - gasleft();

        assertTrue(ok, "receive reverted");
        assertLt(used, 1_000_000, "receive exceeds the protocol ceiling");
        // The ceiling is generous; a compliant body should be nowhere near it, and drifting
        // toward it is the signal worth catching, not the breach itself.
        assertLt(used, 100_000, "receive got expensive enough to be worth looking at");
        emit log_named_uint("receive gas (first, cold)", used);
    }

    // ---------------------------------------------------------------- Rule 001 / 009

    /// @notice The Guardian must reach every privileged function. It is a permanent backup
    ///         caller and nothing in this contract may lock it out.
    function test_GuardianCanReachEveryPrivilegedFunction() public {
        _tax(2 ether);

        uint256 floor_ = _floor(_within(1 ether));
        uint256 amt1_ = _within(1 ether);
        vm.prank(guardian);
        uint256 got = flap.endow(amt1_, floor_);
        assertGt(got, 0, "guardian cannot convert tax");

        uint256 nativeHeld = address(flap).balance;
        vm.prank(guardian);
        flap.emergencyWithdrawNative(SAFE);
        assertEq(address(flap).balance, 0, "guardian cannot drain native");
        assertEq(SAFE.balance, nativeHeld, "the drained native coin did not arrive");

        vm.prank(guardian);
        flap.emergencyWithdrawToken(BTCB, SAFE);
        assertEq(IERC20(BTCB).balanceOf(address(flap)), 0, "guardian cannot recover tokens");
        assertEq(IERC20(BTCB).balanceOf(SAFE), got, "the recovered tokens did not arrive");
    }

    /// @notice And the escape hatch is the Guardian's alone — not the curator's, not anyone's.
    function test_NobodyButTheGuardianReachesTheEscapeHatch() public {
        _tax(1 ether);

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Only the guardian / 仅限守护者"));
        flap.emergencyWithdrawNative(CURATOR);

        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Only the guardian / 仅限守护者"));
        flap.emergencyWithdrawToken(BTCB, ALICE);

        assertEq(address(flap).balance, 1 ether, "the tax moved");
    }

    function test_EmergencyWithdrawRefusesTheZeroAddress() public {
        vm.prank(guardian);
        vm.expectRevert(bytes(unicode"Zero address / 地址为零"));
        flap.emergencyWithdrawNative(address(0));

        vm.prank(guardian);
        vm.expectRevert(bytes(unicode"Zero address / 地址为零"));
        flap.emergencyWithdrawToken(BTCB, address(0));
    }

    /// @notice An empty vault is not an error. Draining nothing is a no-op, not a revert.
    function test_EmergencyWithdrawOnAnEmptyVaultIsSilent() public {
        vm.prank(guardian);
        flap.emergencyWithdrawNative(SAFE);
        vm.prank(guardian);
        flap.emergencyWithdrawToken(BTCB, SAFE);
    }

    // ---------------------------------------------------------------- Rule 003 fairness

    /// @notice A privileged caller may not declare that any price is acceptable.
    ///
    /// @dev Without a lower bound on the floor, the curator could sandwich the vault's own
    ///      conversion and keep the difference. The money being converted is the token's trading
    ///      tax, so that difference comes out of the bounty, not out of them.
    function test_EndowRefusesAFloorAnInsiderCouldSandwich() public {
        _tax(2 ether);
        uint256 spot = flap.quote(_within(1 ether));

        uint256 amt2_ = _within(1 ether);
        vm.prank(guardian);
        vm.expectRevert(bytes(unicode"Slippage floor is too low / 滑点下限过低"));
        flap.endow(amt2_, 0);

        // Ten percent under spot is still "any price you like" at the sizes involved.
        uint256 tooLow = (spot * 90) / 100;
        uint256 amt3_ = _within(1 ether);
        vm.prank(guardian);
        vm.expectRevert(bytes(unicode"Slippage floor is too low / 滑点下限过低"));
        flap.endow(amt3_, tooLow);

        // Just inside the protocol's tolerance is accepted.
        uint256 ok = (spot * 9_800) / 10_000;
        uint256 amt4_ = _within(1 ether);
        vm.prank(guardian);
        assertGt(flap.endow(amt4_, ok), 0, "a reasonable floor was refused");
    }

    // ---------------------------------------------------------------- accounting after Rule 009

    /// @notice The escape hatch moves tokens without touching the ledger, and that is visible.
    ///
    /// @dev Rule 009 fixes the emergency functions verbatim, and they say nothing about
    ///      accounting — so after a drain this contract still reports money behind tasks that is
    ///      no longer here. That is not a bug to hide inside the drain; it is a fact somebody has
    ///      to be able to check, which is why `solvent()` is in the schema as an argument-free
    ///      read rather than an internal assertion.
    function test_SolvencyGoesFalseAfterTheGuardianDrains() public {
        _tax(1 ether);
        uint256 floor_ = _floor(_within(1 ether));
        uint256 amt5_ = _within(1 ether);
        vm.prank(guardian);
        uint256 pot = flap.endow(amt5_, floor_);
        assertTrue(flap.solvent(), "should start covered");

        vm.prank(guardian);
        flap.emergencyWithdrawToken(BTCB, SAFE);

        assertEq(flap.endowed(), pot, "the ledger still claims the bounty is funded");
        assertEq(IERC20(BTCB).balanceOf(address(flap)), 0, "but the tokens are gone");
        assertFalse(flap.solvent(), "and nothing on chain says so");
    }

    // ---------------------------------------------------------------- Rule 006 views

    function test_DescriptionIsNonEmptyAndFollowsState() public {
        string memory idle = flap.description();
        assertGt(bytes(idle).length, 0, "description is empty");

        // Taxed to exactly what the pool will take, so the conversion leaves nothing behind.
        // With a remainder the vault is still, correctly, waiting to convert — and the banner
        // says so, which is the state this asserts its way past.
        uint256 amt6_ = _within(1 ether);
        _tax(amt6_);
        string memory waiting = flap.description();
        assertTrue(
            keccak256(bytes(idle)) != keccak256(bytes(waiting)),
            "description does not move with the vault's state"
        );

        uint256 floor_ = _floor(amt6_);
        vm.prank(guardian);
        flap.endow(amt6_, floor_);
        assertTrue(
            keccak256(bytes(flap.description())) != keccak256(bytes(waiting)),
            "description did not change once a bounty was live"
        );
    }

    function test_SchemaIsShapedTheWayTheSpecRequires() public view {
        VaultUISchema memory schema = flap.vaultUISchema();
        assertGt(bytes(schema.vaultType).length, 0, "vaultType is empty");
        assertGt(bytes(schema.description).length, 0, "schema description is empty");
        assertEq(schema.methods.length, 12, "method count drifted");

        uint256 writes;
        for (uint256 i; i < schema.methods.length; ++i) {
            assertGt(bytes(schema.methods[i].name).length, 0, "a method has no name");
            assertGt(bytes(schema.methods[i].description).length, 0, "a method has no description");
            if (schema.methods[i].isWriteMethod) {
                ++writes;
                assertEq(schema.methods[i].outputs.length, 0, "a write method declares outputs");
            }
        }
        assertEq(writes, 6, "the write methods drifted");
    }

    /// @dev The spec fixes the vocabulary: only these field types, 18 decimals for an amount and
    ///      0 for a raw integer. A UI formats from these, so a wrong one is a wrong number on
    ///      screen rather than a compile error.
    function test_EveryFieldUsesTheSpecVocabulary() public view {
        VaultUISchema memory schema = flap.vaultUISchema();
        for (uint256 i; i < schema.methods.length; ++i) {
            _assertFields(schema.methods[i].inputs);
            _assertFields(schema.methods[i].outputs);
        }
    }

    function _assertFields(FieldDescriptor[] memory fields) private pure {
        for (uint256 i; i < fields.length; ++i) {
            bytes32 ft = keccak256(bytes(fields[i].fieldType));
            bool known = ft == keccak256("string") || ft == keccak256("address")
                || ft == keccak256("uint16") || ft == keccak256("uint128")
                || ft == keccak256("uint256") || ft == keccak256("time")
                || ft == keccak256("bool") || ft == keccak256("bytes")
                || ft == keccak256("bytes32");
            assertTrue(known, string.concat("field type outside the spec: ", fields[i].fieldType));
            assertGt(bytes(fields[i].name).length, 0, "a field has no name");
            assertGt(bytes(fields[i].description).length, 0, "a field has no description");

            // An amount carries 18 decimals and a raw integer carries none. There is no third
            // case in this vault, and a wrong one is a wrong number on screen, not a build error.
            assertTrue(
                fields[i].decimals == 0 || fields[i].decimals == 18,
                string.concat("unexpected decimals on ", fields[i].name)
            );
        }
    }

    // ---------------------------------------------------------------- Rule 002 factory

    function test_FactoryDataSchemaIsDeclared() public view {
        VaultDataSchema memory schema = factory.vaultDataSchema();
        assertGt(bytes(schema.description).length, 0, "factory schema has no description");
        assertEq(schema.fields.length, 0, "newVault takes no vaultData, so no fields may be declared");
        assertFalse(schema.isArray, "an empty field list cannot be an array");
    }

    function test_OnlyTheVaultPortalMayCreateAVault() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Only the vault portal may create a vault / 只有金库门户可以创建金库"));
        factory.newVault(address(token), address(0), CURATOR, "");

        vm.prank(portal);
        address created = factory.newVault(address(token), address(0), CURATOR, "");
        assertTrue(created != address(0), "the portal could not create a vault");
        assertEq(AssayFlapVault(payable(created)).taxToken(), address(token), "wrong token bound");
        assertEq(AssayFlapVault(payable(created)).curator(), CURATOR, "wrong curator bound");
    }

    function test_FactoryTakesNativeQuoteOnly() public view {
        assertTrue(factory.isQuoteTokenSupported(address(0)), "native quote refused");
        assertFalse(factory.isQuoteTokenSupported(BTCB), "an ERC20 quote was accepted");
    }
}
