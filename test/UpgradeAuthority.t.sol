// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import {BaseTest} from "./Base.t.sol";
import {Guardians} from "./Guardians.sol";
import {Stack} from "../script/Stack.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {Tournament} from "../src/Tournament.sol";

/// @notice What Flap asked for, asserted rather than described.
///
/// @dev Flap requires every contract to be upgradeable with the upgrade authority held by their
///      Guardian, so that they can repair a contract and recover funds if something goes wrong.
///      That is a property of a DEPLOYMENT, not of a source file — reading the contracts tells you
///      they can sit behind a beacon, not that they do, nor who owns it. This file asserts it about
///      the stack `script/Stack.sol` actually builds, which is the same stack `script/Deploy.s.sol`
///      broadcasts.
///
///      Flap's Guardian is the upgrade authority on every beacon, which is what they asked for. What
///      these tests are for is the other half: that it is the Guardian on EVERY one of them and
///      nobody else, and that an upgrade preserves the state it is meant to repair.
contract UpgradeAuthorityTest is BaseTest {
    address internal constant NOT_THE_GUARDIAN = address(0xBAD);

    /// @dev Forks BSC testnet and builds the FULL stack, `deployFlap` included. `BaseTest` builds
    ///      only the core, because `PriceGuard.initialize` resolves a router from `block.chainid`
    ///      and refuses a chain Flap is not on — which is right for the fixture and wrong here:
    ///      "every contract sits behind a beacon" cannot be asserted about a stack that is missing
    ///      three of them. Asserting it against the core alone would have passed for four contracts
    ///      and said nothing about the other three.
    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        stack = Stack.deployFlap(
            Stack.Params({
                deployer: address(this),
                guardian: Guardians.TESTNET,
                asset: address(token),
                salvage: SALVAGE,
                registry: address(registry),
                minStake: MIN_STAKE,
                curator: CURATOR
            }),
            stack
        );
        priceGuard = stack.priceGuard;
    }

    function _beacons() internal view returns (address[7] memory b, string[7] memory names) {
        b = [
            stack.beacons.priceGuard,
            stack.beacons.vault,
            stack.beacons.roster,
            stack.beacons.tournament,
            stack.beacons.generator,
            stack.beacons.flapVault,
            stack.beacons.factory
        ];
        names = ["priceGuard", "vault", "roster", "tournament", "generator", "flapVault", "factory"];
    }

    /// @dev Every contract, not the ones we remembered to wire. A new contract added to the stack
    ///      without a beacon fails here rather than at Flap's next review.
    function test_EveryContractSitsBehindABeacon() public view {
        (address[7] memory b, string[7] memory names) = _beacons();
        for (uint256 i; i < b.length; ++i) {
            assertTrue(b[i] != address(0), string.concat(names[i], " has no beacon"));
            assertGt(b[i].code.length, 0, string.concat(names[i], " beacon is not a contract"));
            assertGt(
                UpgradeableBeacon(b[i]).implementation().code.length,
                0,
                string.concat(names[i], " beacon points at no implementation")
            );
        }
    }

    /// @dev And the owner is Flap's Guardian on every one of them. A beacon owned by our own
    ///      deployer would satisfy "upgradeable" and satisfy nothing Flap asked for.
    function test_TheGuardianOwnsEveryBeacon() public view {
        (address[7] memory b, string[7] memory names) = _beacons();
        for (uint256 i; i < b.length; ++i) {
            assertEq(
                UpgradeableBeacon(b[i]).owner(),
                Guardians.TESTNET,
                string.concat(names[i], " beacon is owned by somebody else")
            );
        }
    }

    /// @dev Nobody else can. Checked on every beacon rather than on a representative one, because
    ///      "we used the same helper everywhere" is the claim under test.
    function test_NobodyButTheGuardianCanUpgrade() public {
        (address[7] memory b, string[7] memory names) = _beacons();
        address fresh = address(new PriceGuard());
        for (uint256 i; i < b.length; ++i) {
            vm.prank(NOT_THE_GUARDIAN);
            // OZ 5's custom error, not 4.9's string. The two live side by side in this repo:
            // `UpgradeableBeacon` resolves through @openzeppelin/ (5.4.0) while `Initializable`
            // resolves through @openzeppelin-contracts-upgradeable/ (4.9.6), which is why the
            // assertions in this file are not written in one style.
            vm.expectRevert(
                abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", NOT_THE_GUARDIAN)
            );
            UpgradeableBeacon(b[i]).upgradeTo(fresh);
            assertTrue(
                UpgradeableBeacon(b[i]).implementation() != fresh,
                string.concat(names[i], " was upgraded by a stranger")
            );
        }
    }

    /// @dev The Guardian genuinely can, and the state survives it. An upgrade that silently reset
    ///      storage would repair nothing, so this is the half of "upgradeable" worth asserting.
    function test_TheGuardianCanUpgradeAndStateSurvives() public {
        uint256 before = tournament.taskCount();
        assertGt(before, 0, "the fixture posted no task, so this proves nothing about state");
        address curatorBefore = tournament.curator();
        address generatorBefore = tournament.generator();

        address fresh = address(new Tournament());
        vm.prank(Guardians.TESTNET);
        UpgradeableBeacon(stack.beacons.tournament).upgradeTo(fresh);

        assertEq(UpgradeableBeacon(stack.beacons.tournament).implementation(), fresh, "upgrade did not take");
        assertEq(tournament.taskCount(), before, "task count did not survive the upgrade");
        assertEq(tournament.curator(), curatorBefore, "curator did not survive the upgrade");
        assertEq(tournament.generator(), generatorBefore, "generator did not survive the upgrade");
    }

    /// @dev An implementation must not be usable on its own. Without `_disableInitializers()` in the
    ///      constructor, anyone can initialize the implementation contract and pose as the real one
    ///      — a UI or an indexer reading `curator()` off it would believe them.
    function test_NoImplementationCanBeInitialized() public {
        assertGt(stack.impls.tournament.code.length, 0, "no tournament implementation to test");
        assertGt(stack.impls.priceGuard.code.length, 0, "no price guard implementation to test");

        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        Tournament(stack.impls.tournament).initialize(vault, roster, address(1), address(2));

        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        PriceGuard(stack.impls.priceGuard).initialize();
    }

    /// @dev The one call the compiler cannot refuse. `PriceGuard`'s constructor took no arguments
    ///      before this change and takes none after, so every `new PriceGuard()` left in the tree
    ///      still compiles — and returns a brick: `router` and `reward` are zero, and
    ///      `_disableInitializers()` means it can never be repaired. Every other contract's stale
    ///      call site fails loudly with "Wrong argument count"; this one fails at somebody's launch.
    ///      So the brick is characterised here, and the grep gate in tools/ is what keeps one from
    ///      reaching a deployment.
    function test_ABarePriceGuardIsABrick() public {
        PriceGuard brick = new PriceGuard();
        assertEq(address(brick.router()), address(0), "a bare PriceGuard has a router after all");
        assertEq(address(brick.reward()), address(0), "a bare PriceGuard has a reward token after all");

        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        brick.initialize();

        assertTrue(address(priceGuard.router()) != address(0), "the stack's own guard is not configured");
    }
}
