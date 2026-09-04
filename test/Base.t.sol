// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TaxTokenMock} from "./TaxTokenMock.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {TaskGenerator} from "../src/TaskGenerator.sol";
import {TaskGen} from "../src/TaskGen.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {Crucible} from "../src/Crucible.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {CrucibleHarness} from "./CrucibleHarness.sol";
import {Bytecode} from "./Bytecode.sol";

/// @notice Shared fixture: a live roster, a funded tournament, and a task calibrated against a
///         real measurement of the reference implementation rather than a guessed constant.
abstract contract BaseTest is Test {
    address internal constant CURATOR = address(0xC0);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB0);
    address internal constant CAROL = address(0xCA);
    address internal constant SALVAGE = address(0x5A);

    uint256 internal constant AGENT_ALICE = 11;
    uint256 internal constant AGENT_BOB = 22;
    uint256 internal constant AGENT_CAROL = 33;

    uint256 internal constant MIN_STAKE = 1_000e18;
    uint128 internal constant POT = 100_000e18;
    uint32 internal constant GAS_CAP = 100_000;

    MockIdentityRegistry internal registry;
    TaxTokenMock internal token;
    AssayVault internal vault;
    AgentRoster internal roster;
    Tournament internal tournament;
    TaskGenerator internal generator;
    UpgradeableBeacon internal generatorBeacon;
    address internal generatorImpl;
    address internal constant _FLAP_GUARDIAN_97 = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    CrucibleHarness internal harness;

    uint256 internal taskId;
    uint64 internal commitEnd;
    uint64 internal revealEnd;
    uint32 internal baselineGas;
    uint256 internal referenceGas;

    bytes[] internal inputs;
    bytes32[] internal expected;

    function setUp() public virtual {
        vm.warp(1_800_000_000);

        registry = new MockIdentityRegistry();
        harness = new CrucibleHarness();

        vm.prank(CURATOR);
        token = new TaxTokenMock(CURATOR, 1_000_000_000e18);

        // Custody is a separate contract; the logic contracts only ever instruct it.
        vault = new AssayVault(IERC20(address(token)), SALVAGE);
        roster = new AgentRoster(IIdentityRegistry(address(registry)), vault, MIN_STAKE);
        // The generator is wired the way Deploy.s.sol wires it, prediction and all, so the drawn
        // lane every funding test depends on is the real one rather than a stub.
        generatorImpl = address(new TaskGenerator());
        generatorBeacon = new UpgradeableBeacon(generatorImpl, _FLAP_GUARDIAN_97);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        tournament = new Tournament(vault, roster, CURATOR, predicted);
        generator = TaskGenerator(address(new BeaconProxy(
            address(generatorBeacon), abi.encodeCall(TaskGenerator.initialize, (tournament))
        )));
        require(address(generator) == predicted, "generator prediction missed in the fixture");
        vault.addController(address(roster));
        vault.addController(address(tournament));
        vault.freeze();

        roster.setConsumer(address(tournament));

        registry.mint(AGENT_ALICE, ALICE);
        registry.mint(AGENT_BOB, BOB);
        registry.mint(AGENT_CAROL, CAROL);

        // Task: return the square of the uint256 in calldata.
        uint256[4] memory xs = [uint256(2), 3, 7, 11];
        for (uint256 i; i < xs.length; ++i) {
            inputs.push(abi.encodePacked(xs[i]));
            expected.push(keccak256(abi.encodePacked(xs[i] * xs[i])));
        }

        // Calibrate the baseline by measuring the reference, exactly as a task author would.
        (bool ok, uint256 gasUsed,) = harness.measure(Bytecode.verbose(), _vectors(), GAS_CAP);
        require(ok, "reference implementation must pass its own vectors");
        referenceGas = gasUsed;
        // The chain measures the baseline from this same reference now, so the recorded number is
        // whatever `padded()` actually costs — asserted below rather than assumed.
        baselineGas = uint32(gasUsed);

        commitEnd = uint64(block.timestamp + 1 hours);
        revealEnd = uint64(block.timestamp + 2 hours);

        vm.startPrank(CURATOR);
        token.approve(address(vault), type(uint256).max);
        taskId = tournament.postTask(inputs, expected, Bytecode.verbose(), GAS_CAP, commitEnd, revealEnd, POT);
        // The drawn task. `fundTaskFromPool` pays this lane and no other now, so every test that
        // funds has to compete in a task nobody chose — which is the property, not an inconvenience.
        // Three tiers mirroring Bytecode.verbose/padded/tight, so tests keep the relative scores
        // they were written against:
        //   naive  — PUSH32 per op. The reference the baseline is measured from.
        //   padded — minimal pushes, no constant folding. Beats the baseline; does not win.
        //   tight  — folded and minimal. The best answer the generator's own optimiser knows.
        _postDrawnFixture();

        // Seed miners so they can stake.
        token.transfer(ALICE, MIN_STAKE * 10);
        token.transfer(BOB, MIN_STAKE * 10);
        token.transfer(CAROL, MIN_STAKE * 10);
        vm.stopPrank();
    }

    /// @dev Posts through the generator — the only lane `fundTaskFromPool` pays — and hands back
    ///      what a miner needs to compete in it. The drawn instance is not ours to choose, which is
    ///      the whole point, so a test that funds a task must answer the task the chain drew. That
    ///      is now possible from outside: `drawFor` exposes the same choice `generateAndPost` makes.
    ///
    ///      `naive` is the reference the baseline is measured from; `tight` beats it and scores.
    function _postDrawn()
        internal
        returns (uint256 taskId, bytes memory naive, bytes memory tight)
    {
        bytes32 seed = blockhash(block.number - 1);
        require(seed != bytes32(0), "fixture has no usable blockhash; vm.roll first");

        (TaskGen.Op[] memory ops, bool found) = generator.drawFor(seed);
        require(found, "this seed draws no usable instance");

        taskId = generator.generateAndPost();
        assertEq(taskId, tournament.latestGeneratedTaskId(), "the drawn mark did not advance");

        naive = TaskGen.compileNaive(ops);
        tight = TaskGen.compileTight(TaskGen.optimise(ops));
    }

    /// @dev The vectors of a drawn task, derived the way TaskGenerator derives them.
    function _drawnVectors(bytes32 seed, TaskGen.Op[] memory ops)
        internal
        pure
        returns (bytes[] memory ins, bytes32[] memory exp)
    {
        uint256 n = 8;
        ins = new bytes[](n);
        exp = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            uint256 x = i == 0 ? 0 : i == 1 ? 1 : i == 2 ? type(uint256).max
                : uint256(keccak256(abi.encode(seed, "vec", i)));
            ins[i] = abi.encodePacked(x);
            exp[i] = keccak256(abi.encodePacked(bytes32(TaskGen.eval(ops, x))));
        }
    }

    uint256 internal drawnTaskId;
    bytes internal drawnNaive;
    bytes internal drawnPadded;
    bytes internal drawnTight;
    uint64 internal drawnCommitEnd;
    uint64 internal drawnRevealEnd;

    /// @dev Posts the drawn task the funding tests use, and derives the three programs that answer
    ///      it. `drawFor` exposes the same choice `generateAndPost` makes, so this is the instance
    ///      the chain actually posted rather than a guess at it.
    function _postDrawnFixture() internal {
        bytes32 seed = blockhash(block.number - 1);
        require(seed != bytes32(0), "fixture needs a real parent blockhash");

        (TaskGen.Op[] memory ops, bool found) = generator.drawFor(seed);
        require(found, "this seed draws no usable instance");

        drawnTaskId = generator.generateAndPost();
        require(drawnTaskId == tournament.latestGeneratedTaskId(), "drawn mark did not advance");

        drawnNaive = TaskGen.compileNaive(ops);
        drawnPadded = TaskGen.compileTight(ops);
        drawnTight = TaskGen.compileTight(TaskGen.optimise(ops));

        // `drawnTight` must actually beat the reference or every scoring assertion against this
        // task is vacuous. `generateAndPost` already refuses an instance without that slack, so
        // this restates the guarantee where a test can trip over it rather than trusting it.
        require(keccak256(drawnTight) != keccak256(drawnNaive), "the drawn instance has no slack");

        // The middle tier is whatever the unfolded compilation gives. On some instances constant
        // folding changes nothing and it collapses onto `drawnTight`; that is allowed — a test
        // needing two DISTINCT scores has to check for itself rather than assume the draw provided
        // them.
        if (keccak256(drawnPadded) == keccak256(drawnTight)) drawnPadded = drawnTight;

        (drawnCommitEnd, drawnRevealEnd,,) = tournament.taskGates(drawnTaskId);
    }

    function _vectors() internal view returns (Crucible.Vector[] memory v) {
        v = new Crucible.Vector[](inputs.length);
        for (uint256 i; i < inputs.length; ++i) {
            v[i] = Crucible.Vector({input: inputs[i], expected: expected[i]});
        }
    }

    function _enroll(address miner, uint256 agentId) internal {
        vm.startPrank(miner);
        token.approve(address(vault), type(uint256).max);
        roster.enroll(agentId, MIN_STAKE);
        vm.stopPrank();
    }

    function _commitment(bytes memory runtime, bytes32 salt, uint256 agentId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(runtime, salt, agentId));
    }

    function _commit(address miner, uint256 agentId, bytes memory runtime, bytes32 salt) internal {
        vm.prank(miner);
        tournament.commit(taskId, _commitment(runtime, salt, agentId));
    }

    function _reveal(address miner, bytes memory runtime, bytes32 salt) internal {
        vm.prank(miner);
        tournament.reveal(taskId, runtime, salt);
    }

    /// @dev The drawn task's own commit/reveal. `_commit`/`_reveal` name the curated fixture task,
    ///      and a test that funds has to compete in the drawn one — those are different tasks with
    ///      different vectors now, so committing the curated programs into the drawn task scores
    ///      nothing and reads like a broken assertion rather than a wrong task id.
    function _commitDrawn(address miner, uint256 agentId, bytes memory runtime, bytes32 salt)
        internal
    {
        vm.prank(miner);
        tournament.commit(drawnTaskId, _commitment(runtime, salt, agentId));
    }

    function _revealDrawn(address miner, bytes memory runtime, bytes32 salt) internal {
        vm.prank(miner);
        tournament.reveal(drawnTaskId, runtime, salt);
    }
}
