// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Stack} from "../script/Stack.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {TaxTokenMock} from "./TaxTokenMock.sol";
import {Bytecode} from "./Bytecode.sol";
import {Crucible} from "../src/Crucible.sol";
import {CrucibleHarness} from "./CrucibleHarness.sol";

/// @notice A task's difficulty is MEASURED on chain from the reference the poster supplies.
/// @dev    It used to arrive as a number in calldata with nothing deriving it, which is what these
///         tests were written against. `postTask` runs the reference through the same Crucible that
///         settles a reveal and records what it cost, so a poster can no longer name a difficulty.
contract BaselineTrustTest is Test {
    /// @dev This fixture never posts on the drawn lane, so the generator is a placeholder.
    ///      Naming it says that on purpose rather than leaving a bare address to be read as real.
    address internal constant NO_DRAWN_LANE = address(0xDEAD);

    /// @dev Flap's Guardian on BSC testnet, which owns the beacon behind every contract here.
    address internal constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;

    address constant CURATOR = address(0xC0);
    address constant SALVAGE = address(0x5A);
    address constant STRANGER = address(0x571A);

    Tournament internal tournament;
    CrucibleHarness internal harness;

    function setUp() public {
        vm.warp(1_800_000_000);
        harness = new CrucibleHarness();
        TaxTokenMock token = new TaxTokenMock(CURATOR, 1_000_000_000e18);
        AssayVault custody = Stack.newVault(GUARDIAN, address(token), SALVAGE, address(this));
        AgentRoster roster = Stack.newRoster(GUARDIAN, address(0), custody, 1_000e18, address(this));
        tournament = Stack.newTournament(GUARDIAN, custody, roster, CURATOR, NO_DRAWN_LANE);
        custody.addController(address(roster));
        custody.addController(address(tournament));
        custody.freeze();
        roster.setConsumer(address(tournament));
    }

    function _vec() internal pure returns (bytes[] memory v) {
        v = new bytes[](1);
        v[0] = abi.encodePacked(uint256(3));
    }

    function _exp() internal pure returns (bytes32[] memory e) {
        e = new bytes32[](1);
        e[0] = keccak256(abi.encodePacked(uint256(9)));
    }

    function _vectors() internal pure returns (Crucible.Vector[] memory v) {
        v = new Crucible.Vector[](1);
        v[0] = Crucible.Vector({input: abi.encodePacked(uint256(3)), expected: keccak256(abi.encodePacked(uint256(9)))});
    }

    /// The difficulty is measured from a real implementation, so a poster cannot name one.
    ///
    /// The baseline used to be a calldata parameter whose only check was non-zero. A poster could
    /// pass 1, making the task unwinnable and paying nobody, or 2^32-1, making a deliberately
    /// wasteful submission score. Neither was detectable from the parameters. There is no such
    /// parameter now: the chain runs the supplied reference against these vectors and records what
    /// it costs.
    function test_TheRecordedBaselineIsWhatTheReferenceActuallyCosts() public {
        (bool ok, uint256 measured,) = harness.measure(Bytecode.padded(), _vectors(), 100_000);
        assertTrue(ok, "the reference answers its own vectors");

        vm.prank(STRANGER);
        uint256 id = tournament.postTask(
            _vec(), _exp(), Bytecode.padded(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp + 120), 0
        );
        (,,,, uint32 baseline,,,,) = tournament.tasks(id);
        assertEq(uint256(baseline), measured, "the recorded baseline is not the reference's measured cost");

        // And a tighter program scores against it, which is the whole point of the tournament.
        (bool passed,, uint256 score) = tournament.previewAssay(id, Bytecode.tight());
        assertTrue(passed, "the tight implementation answers the vectors");
        assertGt(score, 0, "a tighter program did not score against a measured baseline");
    }

    /// A reference that does not answer its own vectors is refused, so a posted task is always
    /// answerable by at least the program its difficulty was measured from.
    function test_AReferenceThatFailsItsOwnVectorsIsRejected() public {
        vm.prank(STRANGER);
        vm.expectRevert(bytes(unicode"Reference fails its own vectors / 参考实现跑不过自己的向量"));
        tournament.postTask(
            _vec(), _exp(), Bytecode.wrong(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp + 120), 0
        );
    }

    /// Including one that reverts outright rather than answering wrongly.
    function test_ARevertingReferenceIsRejected() public {
        vm.prank(STRANGER);
        vm.expectRevert(bytes(unicode"Reference fails its own vectors / 参考实现跑不过自己的向量"));
        tournament.postTask(
            _vec(), _exp(), Bytecode.reverting(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp + 120), 0
        );
    }
}
