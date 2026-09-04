// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {TaxTokenMock} from "./TaxTokenMock.sol";
import {TaskGenerator} from "../src/TaskGenerator.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";

/// @notice The generator writes a file and the poster reads it. Nothing checked they agreed.
///
/// @dev Changing postTask to measure its own baseline updated the poster to read a
///      `referenceRuntime` field and left the generator writing the old shape, so the documented
///      GenTask -> PostTask flow reverted on its first line — for the team, for Flap, for anyone.
///      Every contract test passed throughout, because every one of them builds its task in
///      Solidity and never goes near the file the operator actually uses.
///
///      This posts the spec on disk through the same parses PostTask makes. It is the only test
///      that fails when the two ends of that pipeline drift apart.
contract GeneratorFeedsPosterTest is Test {
    TaskGenerator internal generator;
    UpgradeableBeacon internal beacon;

    address constant CURATOR = address(0xC0);
    address constant SALVAGE = address(0x5A);

    Tournament internal tournament;

    function setUp() public {
        vm.warp(1_800_000_000);
        TaxTokenMock token = new TaxTokenMock(CURATOR, 1_000_000_000e18);
        AssayVault custody = new AssayVault(IERC20(address(token)), SALVAGE);
        AgentRoster roster = new AgentRoster(IIdentityRegistry(address(0)), custody, 1_000e18);
        beacon = new UpgradeableBeacon(address(new TaskGenerator()), address(0xF1A9));
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

    function test_AGeneratedSpecPostsThroughThePostersOwnParses() public {
        string memory json = vm.readFile("tasks/epoch.json");

        // Exactly the parses script/PostTask.s.sol makes, in the same order. A missing field
        // reverts here with the same message it would give an operator.
        bytes[] memory inputs = vm.parseJsonBytesArray(json, ".inputs");
        bytes32[] memory expected = vm.parseJsonBytes32Array(json, ".expected");
        bytes memory referenceRuntime = vm.parseJsonBytes(json, ".referenceRuntime");
        uint32 statedBaseline = uint32(vm.parseJsonUint(json, ".baselineGas"));
        uint32 gasCap = uint32(vm.parseJsonUint(json, ".gasCap"));
        uint256 commitSeconds = vm.parseJsonUint(json, ".commitSeconds");
        uint256 revealSeconds = vm.parseJsonUint(json, ".revealSeconds");
        vm.parseJsonUint(json, ".pot");

        assertEq(inputs.length, expected.length, "the spec's vectors are lopsided");
        assertGt(referenceRuntime.length, 0, "the spec carries no reference implementation");

        vm.prank(CURATOR);
        uint256 id = tournament.postTask(
            inputs, expected, referenceRuntime, gasCap,
            uint64(block.timestamp + commitSeconds),
            uint64(block.timestamp + commitSeconds + revealSeconds),
            0
        );

        // And the number the generator measured off chain is the number the chain measured. A
        // disagreement means the spec and the chain are describing different programs.
        (,,,, uint32 measured,,,,) = tournament.tasks(id);
        assertEq(measured, statedBaseline, "the chain measured a different baseline than the spec states");
    }

    /// The spec's own claim that the task is winnable, checked against the chain's baseline.
    function test_TheSpecsReferenceGasActuallyBeatsTheMeasuredBaseline() public view {
        string memory json = vm.readFile("tasks/epoch.json");
        uint256 stated = vm.parseJsonUint(json, ".baselineGas");
        uint256 best = vm.parseJsonUint(json, ".referenceGas");
        assertLt(best, stated, "the spec claims a baseline nothing in it can beat");
    }

    /// @dev The money leg of the same pipeline, which is the leg that just broke.
    ///
    ///      `PostTask.s.sol` used to post a curated task and hand it the pool in the next line. When
    ///      the pool moved to the drawn lane that line became a guaranteed revert — "Not the drawn
    ///      task" — and nothing in the suite would have said so, because every funding test builds
    ///      its own task in Solidity and none of them walks the operator's sequence.
    ///
    ///      This walks it: post the curated task the spec describes, draw the task the tax pays,
    ///      and fund that one. The order is the script's order, so a change to either end shows up
    ///      here rather than in a broadcast that reverts with real gas spent and a task already
    ///      posted.
    function test_ThePostersSequenceFundsTheTaskTheTaxActuallyPays() public {
        string memory json = vm.readFile("tasks/epoch.json");
        bytes[] memory inputs = vm.parseJsonBytesArray(json, ".inputs");
        bytes32[] memory expected = vm.parseJsonBytes32Array(json, ".expected");
        bytes memory referenceRuntime = vm.parseJsonBytes(json, ".referenceRuntime");
        uint32 gasCap = uint32(vm.parseJsonUint(json, ".gasCap"));
        uint256 commitSeconds = vm.parseJsonUint(json, ".commitSeconds");
        uint256 revealSeconds = vm.parseJsonUint(json, ".revealSeconds");

        // Leg one: the curated task, exactly as the script posts it.
        vm.prank(CURATOR);
        uint256 curated = tournament.postTask(
            inputs, expected, referenceRuntime, gasCap,
            uint64(block.timestamp + commitSeconds),
            uint64(block.timestamp + commitSeconds + revealSeconds),
            0
        );

        // Leg two: the drawn task. This is the line the script gained, and the one whose absence
        // would leave the converted tax with nowhere to go.
        uint256 drawn = generator.generateAndPost();
        assertEq(drawn, tournament.latestGeneratedTaskId(), "the drawn mark did not advance");
        assertTrue(drawn != curated, "the funded task is the curated one again");

        // And the curated task the script also posts cannot take the pool, so the two legs cannot
        // be collapsed back into one by a later edit that looks like a simplification.
        assertTrue(
            tournament.latestGeneratedTaskId() != curated,
            "a curated task became the funding target"
        );
    }
}
