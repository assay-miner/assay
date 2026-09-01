// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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

/// @notice The withdrawal gate says "the most recent task has settled". It reads the task with the
///         highest id, which is not the same claim: a task posted later can close earlier.
contract GateBypassTest is Test {
    address constant CURATOR = address(0xC0);
    address constant SALVAGE = address(0x5A);
    address constant TAXPAYER = address(0x7A);

    Tournament internal tournament;
    AssayFlapVault internal flap;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        TaxTokenMock token = new TaxTokenMock(CURATOR, 1_000_000_000e18);
        AssayVault custody = new AssayVault(IERC20(address(token)), SALVAGE);
        AgentRoster roster = new AgentRoster(IIdentityRegistry(address(0)), custody, 1_000e18);
        tournament = new Tournament(custody, roster, CURATOR);
        custody.addController(address(roster));
        custody.addController(address(tournament));
        custody.freeze();
        roster.setConsumer(address(tournament));
        flap = new AssayFlapVault(tournament, address(token), CURATOR, new PriceGuard());
    }

    function _vec() internal pure returns (bytes[] memory v) {
        v = new bytes[](1);
        v[0] = abi.encodePacked(uint256(2));
    }

    function _exp() internal pure returns (bytes32[] memory e) {
        e = new bytes32[](1);
        e[0] = keccak256(abi.encodePacked(uint256(4)));
    }

    /// A long task is open and a miner is working in it. The curator posts a second, short task
    /// and waits two minutes for that one to close. The gate must stay shut, because the first
    /// task has not settled — it did not, until latestRevealEnd became a high-water mark instead
    /// of a lookup of the newest task, and the tax walked out from under a working miner.
    function test_AShortTaskCannotOpenTheGateOnALongOneStillRunning() public {
        vm.deal(TAXPAYER, 1 ether);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: 0.5 ether}("");
        require(ok, "tax");

        // Task 1: a long window, still open throughout this test.
        vm.prank(CURATOR);
        uint256 long_ = tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 3600), uint64(block.timestamp + 7200), 0
        );

        // The gate holds, as intended.
        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Epoch open / 本期未结束"));
        flap.withdrawUnconverted(0);

        // Task 2: posted later, closes sooner.
        vm.prank(CURATOR);
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp + 120), 0);
        vm.warp(block.timestamp + 121);

        (,, uint64 longReveal,,,,,,) = tournament.tasks(long_);
        assertGt(uint256(longReveal), block.timestamp, "task 1 must still be open for this to be the bug");

        // The gate stays shut for everyone while task 1 runs.
        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Epoch open / 本期未结束"));
        flap.withdrawUnconverted(0);

        // And opens once the long task actually settles.
        vm.warp(uint256(longReveal));
        uint256 before = CURATOR.balance;
        vm.prank(CURATOR);
        uint256 sent = flap.withdrawUnconverted(0);
        assertEq(sent, 0.5 ether, "the gate never opened");
        assertEq(CURATOR.balance, before + 0.5 ether, "the project did not receive it");
    }

    /// Anyone may post once the previous task has settled. This is what keeps the tournament
    /// running if the curator goes quiet, and it is the reviewer's own suggestion.
    function test_AStrangerMayPostOnceNothingIsLive() public {
        address stranger = address(0x571A);
        vm.prank(stranger);
        uint256 id = tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp + 120), 0
        );
        assertGt(id, 0, "a stranger could not post into an empty gap");
    }

    /// But not while one is running.
    function test_AStrangerCannotPostWhileATaskIsLive() public {
        vm.prank(CURATOR);
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp + 120), 0);

        vm.prank(address(0x571A));
        vm.expectRevert(bytes(unicode"Not the curator / 非策展方"));
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp + 120), 0);
    }

    /// And not for a window long enough to matter.
    ///
    /// This is the whole reason open posting is bounded. `latestRevealEnd` is a high-water mark no
    /// later post can walk back, so a stranger posting MAX_TASK_SPAN would freeze the project's own
    /// tax for thirty days for the price of gas, with nothing able to undo it.
    function test_AStrangerCannotFreezeTheTaxWithALongWindow() public {
        // Both views read before any prank or expectRevert: a view call sitting in the argument
        // list is the next call, and it consumes them.
        uint64 maxSpan = tournament.MAX_TASK_SPAN();
        uint64 openSpan = tournament.OPEN_POST_MAX_SPAN();

        vm.prank(address(0x571A));
        vm.expectRevert(bytes(unicode"Bad window / 时间窗口不合法"));
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp) + maxSpan, 0
        );

        // Ten minutes is the most they can hold it, and the curator keeps the full range.
        vm.prank(address(0x571A));
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
        tournament.postTask(_vec(), _exp(), Bytecode.tight(), 100_000, uint64(block.timestamp + 60), uint64(block.timestamp + 120), 0);
        assertEq(tournament.latestRevealEnd(), high, "a shorter task moved the pointer backwards");
    }
}
