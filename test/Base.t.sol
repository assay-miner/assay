// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TaxTokenMock} from "./TaxTokenMock.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
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
        roster = new AgentRoster(IIdentityRegistry(address(registry)), vault, MIN_STAKE, CURATOR);
        tournament = new Tournament(vault, roster, CURATOR);
        vault.addController(address(roster));
        vault.addController(address(tournament));
        vault.freeze();

        vm.prank(CURATOR);
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
        (bool ok, uint256 gasUsed,) = harness.measure(Bytecode.padded(), _vectors(), GAS_CAP);
        require(ok, "reference implementation must pass its own vectors");
        referenceGas = gasUsed;
        baselineGas = uint32(gasUsed * 2);

        commitEnd = uint64(block.timestamp + 1 hours);
        revealEnd = uint64(block.timestamp + 2 hours);

        vm.startPrank(CURATOR);
        token.approve(address(vault), type(uint256).max);
        taskId = tournament.postTask(inputs, expected, baselineGas, GAS_CAP, commitEnd, revealEnd, POT);
        // Seed miners so they can stake.
        token.transfer(ALICE, MIN_STAKE * 10);
        token.transfer(BOB, MIN_STAKE * 10);
        token.transfer(CAROL, MIN_STAKE * 10);
        vm.stopPrank();
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
}
