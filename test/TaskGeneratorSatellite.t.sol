// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {TaskGenerator} from "../src/TaskGenerator.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {TaxTokenMock} from "./TaxTokenMock.sol";

/// @notice A user with no tooling posts a task, and Flap owns the recipe.
contract TaskGeneratorSatelliteTest is Test {
    address constant CURATOR = address(0xC0);
    address constant SALVAGE = address(0x5A);
    address constant STRANGER = address(0x571A);
    address constant GUARDIAN_56 = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;

    Tournament internal tournament;
    TaskGenerator internal generator;
    UpgradeableBeacon internal beacon;

    function setUp() public {
        vm.chainId(56);
        vm.warp(1_800_000_000);
        vm.roll(40_000_000);

        TaxTokenMock token = new TaxTokenMock(CURATOR, 1_000_000_000e18);
        AssayVault custody = new AssayVault(IERC20(address(token)), SALVAGE);
        AgentRoster roster = new AgentRoster(IIdentityRegistry(address(0)), custody, 1_000e18);
        tournament = new Tournament(custody, roster, CURATOR);
        custody.addController(address(roster));
        custody.addController(address(tournament));
        custody.freeze();
        roster.setConsumer(address(tournament));

        // Flap's Guardian owns the beacon: the same address the tournament and the vault already
        // treat as the trusted operator, so this adds no party that was not already trusted.
        beacon = new UpgradeableBeacon(address(new TaskGenerator()), GUARDIAN_56);
        generator = TaskGenerator(address(new BeaconProxy(
            address(beacon), abi.encodeCall(TaskGenerator.initialize, (tournament))
        )));
    }

    /// The whole point: no tooling, no arguments, no permission.
    function test_AStrangerPostsATaskWithNoToolingAndNoArguments() public {
        vm.prank(STRANGER);
        uint256 id = generator.generateAndPost(60, 60);
        assertGt(id, 0, "a stranger could not generate and post");

        (address poster,,,, uint32 baseline,,,,) = tournament.tasks(id);
        assertEq(poster, address(generator), "the generator is the poster");
        assertGt(baseline, 0, "the chain recorded no baseline");
        assertEq(tournament.vectorCount(id), generator.VECTORS(), "wrong vector count");
    }

    /// The tournament's own rules still apply to it — it posts as a stranger, not as an insider.
    function test_TheGeneratorIsBoundByTheOpenPostRules() public {
        vm.prank(CURATOR);
        tournament.postTask(
            _oneVector(), _oneExpected(), _square(), 100_000,
            uint64(block.timestamp + 600), uint64(block.timestamp + 1200), 0
        );
        vm.prank(STRANGER);
        vm.expectRevert(bytes(unicode"Not the curator / 非策展方"));
        generator.generateAndPost(60, 60);
    }

    /// And it cannot be used to reach past that bound.
    function test_TheGeneratorCannotPostALongWindow() public {
        uint64 openSpan = tournament.OPEN_POST_MAX_SPAN();
        vm.prank(STRANGER);
        vm.expectRevert(bytes(unicode"Bad window / 时间窗口不合法"));
        generator.generateAndPost(60, openSpan);
    }

    /// Flap can change how a task is drawn without anybody redeploying the tournament.
    function test_TheGuardianCanUpgradeTheRecipe() public {
        address next = address(new TaskGenerator());
        vm.prank(GUARDIAN_56);
        beacon.upgradeTo(next);
        assertEq(beacon.implementation(), next, "the Guardian could not upgrade");
    }

    /// And nobody else can.
    function test_NobodyElseCanUpgradeTheRecipe() public {
        address next = address(new TaskGenerator());
        vm.prank(STRANGER);
        vm.expectRevert();
        beacon.upgradeTo(next);
        vm.prank(CURATOR);
        vm.expectRevert();
        beacon.upgradeTo(next);
    }

    /// Consecutive blocks draw different tasks, so the answer to one is worthless to the next.
    function test_ADifferentBlockDrawsADifferentTask() public {
        vm.prank(STRANGER);
        uint256 first = generator.generateAndPost(60, 60);
        bytes32 a = tournament.vectorAt(first, 3).expected;

        vm.warp(block.timestamp + 1201);
        vm.roll(block.number + 1);
        vm.prank(STRANGER);
        uint256 second = generator.generateAndPost(60, 60);
        bytes32 b = tournament.vectorAt(second, 3).expected;

        assertTrue(a != b, "two blocks drew the same task");
    }

    /// Every block must yield a task, not just the lucky ones.
    ///
    /// A single draw collapses its vectors or comes out with no slack often enough that a
    /// no-argument call would fail most of the time — which is exactly what happened when this
    /// contract was first written without the redraw the off-chain generator has. Twenty
    /// consecutive blocks is enough to catch that; one is not.
    function test_EveryBlockYieldsATask() public {
        // Carried explicitly rather than read from block.* each turn: under via-ir the compiler
        // hoists those reads out of the loop, so every vm.warp got the same pre-loop value and the
        // clock never actually moved. The trace showed warp(1800000200) twice in a row.
        uint256 at = block.timestamp;
        uint256 height = block.number;
        for (uint256 i; i < 20; ++i) {
            vm.prank(STRANGER);
            uint256 id = generator.generateAndPost(60, 60);
            assertGt(id, 0, "a block produced no task");
            at += 200;
            height += 1;
            vm.warp(at);
            vm.roll(height);
        }
    }

    function _square() internal pure returns (bytes memory) {
        return hex"600035800260005260206000f3";
    }

    function _oneVector() internal pure returns (bytes[] memory v) {
        v = new bytes[](1);
        v[0] = abi.encodePacked(uint256(3));
    }

    function _oneExpected() internal pure returns (bytes32[] memory e) {
        e = new bytes32[](1);
        e[0] = keccak256(abi.encodePacked(uint256(9)));
    }
}
