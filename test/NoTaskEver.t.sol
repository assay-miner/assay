// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Bytecode} from "./Bytecode.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {TaxTokenMock} from "./TaxTokenMock.sol";

/// @notice The case the whole design rests on and no test had ever run: a window in which nothing
///         was published at all.
///
/// @dev The withdrawal is gated on the most recent task having settled. With no task ever posted
///      there is no "most recent", and reasoning that `latestRevealEnd()` returns zero so the
///      comparison passes is not the same as watching the money arrive. Every other test in this
///      repo builds a tournament that already has a task in it, so this path had never executed.
contract NoTaskEverTest is Test {
    address constant CURATOR = address(0xC0);
    address constant SALVAGE = address(0x5A);
    address constant TAXPAYER = address(0x7A);
    address constant STRANGER = address(0x571A);

    Tournament internal tournament;
    AssayFlapVault internal flap;

    function setUp() public {
        // Forked: the vault's constructor resolves the router and reads WETH() from it.
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        TaxTokenMock token = new TaxTokenMock(CURATOR, 1_000_000_000e18);
        AssayVault custody = new AssayVault(IERC20(address(token)), SALVAGE);
        AgentRoster roster = new AgentRoster(IIdentityRegistry(address(0)), custody, 1_000e18);
        tournament = new Tournament(custody, roster, CURATOR);
        custody.addController(address(roster));
        custody.addController(address(tournament));
        custody.freeze();
        roster.setConsumer(address(tournament));

        flap = new AssayFlapVault(tournament, address(token), CURATOR);
    }

    function _tax(uint256 amount) internal {
        vm.deal(TAXPAYER, amount);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: amount}("");
        require(ok, "tax transfer failed");
    }

    /// A window nobody published a task into settles to the project, immediately.
    function test_TaxIsWithdrawableWhenNoTaskWasEverPosted() public {
        assertEq(tournament.taskCount(), 0, "the fixture already has a task");
        assertEq(tournament.latestRevealEnd(), 0, "there is no epoch to wait for");

        _tax(0.05 ether);
        uint256 before = CURATOR.balance;

        vm.prank(CURATOR);
        uint256 sent = flap.withdrawUnconverted(0);

        assertEq(sent, 0.05 ether, "the window did not settle in full");
        assertEq(CURATOR.balance, before + 0.05 ether, "the project did not receive it");
        assertEq(address(flap).balance, 0, "something was left behind");
    }

    /// And a stranger can settle it too — they just cannot keep any of it.
    function test_AStrangerMaySettleAWindowWithNoTask() public {
        _tax(0.05 ether);
        uint256 before = CURATOR.balance;
        uint256 strangerBefore = STRANGER.balance;

        vm.prank(STRANGER);
        flap.withdrawUnconverted(0);

        assertEq(CURATOR.balance, before + 0.05 ether, "the project did not receive it");
        assertEq(STRANGER.balance, strangerBefore, "the caller kept some of it");
    }

    /// How long a withdrawal can be held up, at the worst. The gate waits on the most recent
    /// task's reveal, so the answer is whatever the longest legal task is — and that is bounded.
    /// Without MAX_TASK_SPAN a single task could have pinned this open forever.
    function test_TheLongestAWindowCanBeHeldOpenIsBounded() public {
        _tax(0.05 ether);
        uint64 span = tournament.MAX_TASK_SPAN();

        vm.prank(CURATOR);
        tournament.postTask(_oneVector(), _oneExpected(), Bytecode.tight(), 100_000,
            uint64(block.timestamp + 60), uint64(block.timestamp) + span, 0
        );

        // Held, right up to the bound.
        vm.warp(block.timestamp + span - 1);
        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Epoch open / 本期未结束"));
        flap.withdrawUnconverted(0);

        // And released at it. Thirty days is the ceiling, not forever.
        vm.warp(block.timestamp + 1);
        uint256 before = CURATOR.balance;
        vm.prank(STRANGER);
        flap.withdrawUnconverted(0);
        assertEq(CURATOR.balance, before + 0.05 ether, "the window never released");
        assertEq(uint256(span), 30 days, "the ceiling moved");
    }

    function _oneVector() internal pure returns (bytes[] memory v) {
        v = new bytes[](1);
        v[0] = abi.encodePacked(uint256(2));
    }

    function _oneExpected() internal pure returns (bytes32[] memory e) {
        e = new bytes32[](1);
        e[0] = keccak256(abi.encodePacked(uint256(4)));
    }

    /// Tax that keeps arriving with nothing published keeps being withdrawable. It cannot pile up
    /// unreachable, which is the failure this whole path exists to prevent.
    function test_TaxKeepsSettlingWindowAfterWindow() public {
        for (uint256 i; i < 5; ++i) {
            _tax(0.01 ether);
            vm.warp(block.timestamp + 120); // one epoch
            vm.prank(CURATOR);
            uint256 sent = flap.withdrawUnconverted(0);
            assertEq(sent, 0.01 ether, "an epoch did not settle");
        }
        assertEq(address(flap).balance, 0, "tax accumulated out of reach");
    }
}
