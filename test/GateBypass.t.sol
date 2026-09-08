// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Stack} from "../script/Stack.sol" ;
import {Guardians} from "./Guardians.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Bytecode} from "./Bytecode.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {TaxTokenMock} from "./TaxTokenMock.sol";

/// @notice The open-post gate waits on `latestRevealEnd`, a high-water mark, rather than on "the
///         most recent task". Those are not the same claim — a task posted later can close earlier
///         — and reading the mark is what makes the difference safe.
///
/// @dev This gate used to guard the vault's tax as well, through `withdrawUnconverted` and the
///      curated twin of this mark. That withdrawal is gone: idle tax stays in the vault, converts
///      into the reward pool and lands behind the drawn task for miners to collect, and the only
///      way it reaches a non-miner is Flap's Guardian. So the tests below assert the mark where it
///      still decides something — who may post, and when — and assert of the money that no
///      arrangement of tasks moves a wei of it out of the vault at all.
contract GateBypassTest is Test {
    /// @dev This fixture never posts on the drawn lane, so the generator is a placeholder.
    ///      Naming it says that on purpose rather than leaving a bare address to be read as real.
    address internal constant NO_DRAWN_LANE = address(0xDEAD);

    address constant CURATOR = address(0xC0);
    address constant SALVAGE = address(0x5A);
    address constant TAXPAYER = address(0x7A);
    address constant STRANGER = address(0x571A);

    Tournament internal tournament;
    AssayFlapVault internal flap;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        TaxTokenMock token = new TaxTokenMock(CURATOR, 1_000_000_000e18);
        AssayVault custody = Stack.newVault(Guardians.TESTNET, address(token), SALVAGE, address(this));
        AgentRoster roster = Stack.newRoster(Guardians.TESTNET, address(0), custody, 1_000e18, address(this));
        tournament = Stack.newTournament(Guardians.TESTNET, custody, roster, CURATOR, NO_DRAWN_LANE);
        custody.addController(address(roster));
        custody.addController(address(tournament));
        custody.freeze();
        roster.setConsumer(address(tournament));
        flap = Stack.newFlapVault(Guardians.TESTNET, tournament, address(token), Stack.newPriceGuard(Guardians.TESTNET));
    }

    function _vec() internal pure returns (bytes[] memory v) {
        v = new bytes[](1);
        v[0] = abi.encodePacked(uint256(2));
    }

    function _exp() internal pure returns (bytes32[] memory e) {
        e = new bytes32[](1);
        e[0] = keccak256(abi.encodePacked(uint256(4)));
    }

    /// A long task is open and a stranger wants the lane. They post a second, short task through
    /// the curator and wait two minutes for that one to close. The gate must stay shut, because
    /// the first task has not settled — it did not, until `latestRevealEnd` became a high-water
    /// mark instead of a lookup of the newest task.
    ///
    /// And the tax is not part of this any more, which the second half asserts: whatever the tasks
    /// do, the BNB that arrived stays in the vault. There is no call that pays it out to the
    /// curator, so no ordering of posts can time one.
    function test_AShortTaskCannotOpenTheStrangerLaneOnALongOneStillRunning() public {
        uint256 curatorBefore = CURATOR.balance;
        vm.deal(TAXPAYER, 1 ether);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: 0.5 ether}("");
        require(ok, "tax");

        // Task 1: a long window, still open throughout this test.
        vm.prank(CURATOR);
        uint256 long_ = tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 3600), uint64(block.timestamp + 7200), 0
        );

        // The gate holds, as intended.
        vm.prank(STRANGER);
        vm.expectRevert(bytes(unicode"Not the curator / 非策展方"));
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp + 120), 0);

        // Task 2: posted later, closes sooner.
        vm.prank(CURATOR);
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 600), uint64(block.timestamp + 1200), 0);
        vm.warp(block.timestamp + 1201);

        (,, uint64 longReveal,,,,,,) = tournament.tasks(long_);
        assertGt(uint256(longReveal), block.timestamp, "task 1 must still be open for this to be the bug");

        // The gate stays shut while task 1 runs.
        //
        // `vm.getBlockTimestamp()` rather than `block.timestamp` from here on. Under via-IR the
        // compiler hoists a `block.timestamp` read above the `vm.warp` that precedes it and reuses
        // the pre-warp value, so the windows below were being built from the time this test
        // started rather than from the time it had warped to. The cheatcode returns data and
        // cannot be folded away.
        uint64 nowTs = uint64(vm.getBlockTimestamp());
        vm.prank(STRANGER);
        vm.expectRevert(bytes(unicode"Not the curator / 非策展方"));
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, nowTs + 60, nowTs + 120, 0);

        // And opens once the long task actually settles.
        vm.warp(uint256(longReveal));
        nowTs = uint64(vm.getBlockTimestamp());
        vm.prank(STRANGER);
        assertGt(
            tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, nowTs + 60, nowTs + 120, 0),
            0,
            "the gate never opened"
        );

        // The money did not move at any point in that sequence, and there is nothing to call that
        // would have moved it: `withdrawUnconverted` was the one path out to a non-miner and it is
        // gone. The selector is asserted absent rather than argued about — the vault has no
        // fallback, so a call to a function it does not have reverts.
        (bool gone,) = address(flap).call(abi.encodeWithSignature("withdrawUnconverted(uint256)", uint256(0)));
        assertFalse(gone, "the withdrawal is still reachable");
        assertEq(address(flap).balance, 0.5 ether, "the tax did not stay in the vault");
        assertEq(CURATOR.balance, curatorBefore, "the tax reached the curator");
    }

    /// Anyone may post once the previous task has settled. This is what keeps the tournament
    /// running if the curator goes quiet, and it is the reviewer's own suggestion.
    function test_AStrangerMayPostOnceNothingIsLive() public {
        vm.prank(STRANGER);
        uint256 id = tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp + 120), 0
        );
        assertGt(id, 0, "a stranger could not post into an empty gap");
    }

    /// But not while one is running.
    function test_AStrangerCannotPostWhileATaskIsLive() public {
        vm.prank(CURATOR);
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 600), uint64(block.timestamp + 1200), 0);

        vm.prank(STRANGER);
        vm.expectRevert(bytes(unicode"Not the curator / 非策展方"));
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp + 120), 0);
    }

    /// And not for a window long enough to matter.
    ///
    /// This is the whole reason open posting is bounded. `latestRevealEnd` is a high-water mark no
    /// later post can walk back, so without the cap a stranger posting MAX_TASK_SPAN would hold the
    /// lane shut against every other poster for thirty days for the price of gas, with nothing able
    /// to undo it. The tax is no longer among the things that would have been held: it stays in the
    /// vault whatever is posted, and the conversion path never reads this mark at all.
    function test_AStrangerCannotHoldTheLaneWithALongWindow() public {
        // Both views read before any prank or expectRevert: a view call sitting in the argument
        // list is the next call, and it consumes them.
        uint64 maxSpan = tournament.MAX_TASK_SPAN();
        uint64 openSpan = tournament.OPEN_POST_MAX_SPAN();

        vm.prank(STRANGER);
        vm.expectRevert(bytes(unicode"Bad window / 时间窗口不合法"));
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp) + maxSpan, 0
        );

        // Ten minutes is the most they can hold it, and the curator keeps the full range.
        vm.prank(STRANGER);
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp) + openSpan, 0
        );
        assertLe(
            uint256(tournament.latestRevealEnd()) - block.timestamp,
            uint256(openSpan),
            "a stranger moved the pointer further than the open-post bound"
        );
    }

    /// The pointer only ever moves forward, whatever order tasks arrive in.
    function test_TheRevealPointerIsMonotonic() public {
        vm.prank(CURATOR);
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 3600), uint64(block.timestamp + 7200), 0);
        uint64 high = tournament.latestRevealEnd();
        vm.prank(CURATOR);
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 600), uint64(block.timestamp + 1200), 0);
        assertEq(tournament.latestRevealEnd(), high, "a shorter task moved the pointer backwards");
    }

}
