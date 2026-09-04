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
    /// @dev This fixture never posts on the drawn lane, so the generator is a placeholder.
    ///      Naming it says that on purpose rather than leaving a bare address to be read as real.
    address internal constant NO_DRAWN_LANE = address(0xDEAD);

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
        // Flap's Guardian owns the beacon: the same address the tournament and the vault already
        // treat as the trusted operator, so this adds no party that was not already trusted.
        // Same shape as Deploy.s.sol: the implementation and beacon first, so the proxy is the very
        // next deploy after the tournament and the prediction offset is one rather than a count of
        // whatever happens to sit between them. The custody wiring has to follow, not precede — it
        // names the tournament, and naming it before it exists passed address(0) into addController.
        beacon = new UpgradeableBeacon(address(new TaskGenerator()), GUARDIAN_56);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        tournament = new Tournament(custody, roster, CURATOR, predicted);
        generator = TaskGenerator(address(new BeaconProxy(
            address(beacon), abi.encodeCall(TaskGenerator.initialize, (tournament))
        )));
        require(address(generator) == predicted, "generator prediction missed in the fixture");

        custody.addController(address(roster));
        custody.addController(address(tournament));
        custody.freeze();
        roster.setConsumer(address(tournament));
    }

    /// The whole point: no tooling, no arguments, no permission.
    function test_AStrangerPostsATaskWithNoToolingAndNoArguments() public {
        vm.prank(STRANGER);
        uint256 id = generator.generateAndPost();
        assertGt(id, 0, "a stranger could not generate and post");

        (address poster,,,, uint32 baseline,,,,) = tournament.tasks(id);
        assertEq(poster, address(generator), "the generator is the poster");
        assertGt(baseline, 0, "the chain recorded no baseline");
        assertEq(tournament.vectorCount(id), generator.VECTORS(), "wrong vector count");
    }

    /// The tournament's own rules still apply to it — it posts as a stranger, not as an insider.
    /// @dev The drawn lane is deliberately NOT gated on `latestRevealEnd`. It used to be — the
    ///      generator posted as a stranger and waited its turn like one. That cannot stand now that
    ///      the reward pool follows this lane: whoever wins the race to occupy the open slot would
    ///      be able to hold the treasury's only route to miners shut indefinitely, which is exactly
    ///      the griefing mechanism finding 023 describes, pointed at the money instead of at
    ///      availability.
    function test_TheDrawnLaneIsNotBlockedByALiveTask() public {
        vm.prank(CURATOR);
        tournament.postTask(
            _oneVector(), _oneExpected(), _square(), 100_000,
            uint64(block.timestamp + 600), uint64(block.timestamp + 1200), 0
        );

        // A curated task is live and its reveal is far in the future. The generator posts anyway.
        uint256 id = generator.generateAndPost();
        assertEq(id, tournament.latestGeneratedTaskId(), "the drawn task did not become the target");
    }

    /// @dev The caller cannot name the window. If they could, they would name a short one, trigger
    ///      the draw, and be the only person with time to answer the task the pool is about to fund
    ///      — reintroducing on this lane the head start that moving the pool here removes.
    function test_TheGeneratorsWindowIsNotCallerChosen() public {
        vm.prank(STRANGER);
        uint256 id = generator.generateAndPost();

        (uint64 commitEnd, uint64 revealEnd,,) = tournament.taskGates(id);
        assertEq(
            uint256(commitEnd), block.timestamp + generator.COMMIT_SECONDS(), "commit window is not the constant"
        );
        assertEq(
            uint256(revealEnd),
            block.timestamp + generator.COMMIT_SECONDS() + generator.REVEAL_SECONDS(),
            "reveal window is not the constant"
        );

        // And both clear the floors Tournament enforces on this lane, so the belt and the braces
        // agree rather than one of them being the only thing holding.
        assertGe(uint256(commitEnd), block.timestamp + tournament.MIN_COMMIT_SPAN(), "under the commit floor");
        assertGe(uint256(revealEnd), uint256(commitEnd) + tournament.MIN_REVEAL_SPAN(), "under the reveal floor");
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
        uint256 first = generator.generateAndPost();
        bytes32 a = tournament.vectorAt(first, 3).expected;

        vm.warp(block.timestamp + 1201);
        vm.roll(block.number + 1);
        vm.prank(STRANGER);
        uint256 second = generator.generateAndPost();
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
            uint256 id = generator.generateAndPost();
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
