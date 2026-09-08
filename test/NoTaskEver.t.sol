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

/// @notice The case the whole design rests on and no test had ever run: a window in which nothing
///         was published at all.
///
/// @dev This file was written when a finished window paid its idle tax out to a curator, and the
///      question was whether a tournament with no task in it ever counted as finished. There is no
///      such payment any more: tax stays in the vault, becomes BTCB in `rewardPool`, and is put
///      behind the drawn task for miners to collect. So the question this file asks now is what an
///      empty tournament does to that route — whether the money waits, or is lost, or can be
///      reached by somebody while it waits. Every other test in this repo builds a tournament that
///      already has a task in it, so these paths still execute nowhere else.
contract NoTaskEverTest is Test {
    /// @dev This fixture never posts on the drawn lane, so the generator is a placeholder.
    ///      Naming it says that on purpose rather than leaving a bare address to be read as real.
    address internal constant NO_DRAWN_LANE = address(0xDEAD);

    address constant CURATOR = address(0xC0);
    address constant SALVAGE = address(0x5A);
    address constant TAXPAYER = address(0x7A);
    address constant STRANGER = address(0x571A);
    address constant BTCB = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8;
    address constant TRIGGER = 0x560E9830926C9e0EB98a59c6b9902383Fc0D9Eb2;

    Tournament internal tournament;
    AssayFlapVault internal flap;

    function setUp() public {
        // Forked: the vault's constructor resolves the router and reads WETH() from it.
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

    function _tax(uint256 amount) internal {
        vm.deal(TAXPAYER, amount);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: amount}("");
        require(ok, "tax transfer failed");
    }

    /// A window nobody published a task into leaves the tax exactly where it is, and there is no
    /// call that would move it out. The one there used to be paid a curator, and it is gone.
    ///
    /// Asserted by selector: this file cannot name a function the vault no longer declares, and the
    /// vault has no `fallback`, so an unimplemented selector reverts for every caller.
    function test_TaxStaysInTheVaultWhenNoTaskWasEverPosted() public {
        assertEq(tournament.taskCount(), 0, "the fixture already has a task");
        assertEq(tournament.latestRevealEnd(), 0, "there is no epoch to wait for");

        _tax(0.05 ether);
        uint256 before = CURATOR.balance;

        bytes memory gone = abi.encodeWithSignature("withdrawUnconverted(uint256)", uint256(0));
        address[3] memory callers = [CURATOR, STRANGER, Guardians.TESTNET];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            (bool ok,) = address(flap).call(gone);
            assertFalse(ok, "the withdrawal is still reachable");
        }

        assertEq(address(flap).balance, 0.05 ether, "the tax did not stay in the vault");
        assertEq(flap.freeTax(), 0.05 ether, "and it is not free to be converted");
        assertEq(CURATOR.balance, before, "the tax reached the curator");
    }

    /// And a stranger can still set it moving — they just cannot keep any of it, and with no task
    /// in existence the proceeds wait in the pool rather than going anywhere.
    function test_AStrangerMayConvertAWindowWithNoTaskAndKeepsNoneOfIt() public {
        _tax(0.05 ether);
        uint256 before = CURATOR.balance;
        uint256 strangerBtcb = IERC20(BTCB).balanceOf(STRANGER);

        uint256 fee = flap.schedulerFee();
        // Dealt exactly the fee, so any BNB they hold afterwards came out of the vault.
        vm.deal(STRANGER, fee);
        vm.prank(STRANGER);
        uint256 id = flap.triggerConversion{value: fee}();
        assertGt(id, 0, "an empty tournament stopped the conversion being armed");

        vm.prank(TRIGGER);
        flap.trigger(id);

        assertGt(flap.rewardPool(), 0, "the tax did not become prize money");
        assertEq(flap.endowed(), flap.rewardPool(), "the pool is not what the ledger says it is");
        assertTrue(flap.solvent(), "the vault cannot cover what its ledger claims");
        assertEq(STRANGER.balance, 0, "the caller was paid out of the tax");
        assertEq(IERC20(BTCB).balanceOf(STRANGER), strangerBtcb, "the caller took the proceeds");
        assertEq(CURATOR.balance, before, "the tax reached the curator");

        // Waiting, not lost: there is simply no task yet to put it behind.
        vm.expectRevert(bytes(unicode"No such task / 该任务不存在"));
        flap.fundTaskFromPool(1);
    }

    /// A task holding the longest legal window used to hold the withdrawal shut with it, so the
    /// worst-case delay was whatever MAX_TASK_SPAN allowed. Nothing waits on a task now — the
    /// conversion path never reads the tournament at all — so the ceiling bounds only how long one
    /// task may lock a miner's stake. Asserted here so a change to it is still noticed.
    function test_ALongTaskNoLongerHoldsTheTaxAtAll() public {
        _tax(0.05 ether);
        uint64 span = tournament.MAX_TASK_SPAN();

        vm.prank(CURATOR);
        tournament.postTask(_oneVector(), _oneExpected(), Bytecode.tight(), 100_000,
            uint64(block.timestamp + 600), uint64(block.timestamp) + span, 0
        );

        // Right in the middle of a thirty-day task, and the tax converts anyway.
        vm.warp(block.timestamp + span / 2);
        uint256 fee = flap.schedulerFee();
        vm.deal(STRANGER, fee);
        vm.prank(STRANGER);
        uint256 id = flap.triggerConversion{value: fee}();
        vm.prank(TRIGGER);
        flap.trigger(id);

        assertGt(flap.rewardPool(), 0, "a live task held the conversion");
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

    /// Tax that keeps arriving with nothing published accumulates, and stays convertible the whole
    /// time. It cannot pile up unreachable, which is the failure this path exists to prevent — and
    /// "reachable" now means it can still be turned into prize money, not that somebody can take it.
    function test_TaxKeepsAccumulatingAndStaysConvertible() public {
        for (uint256 i; i < 5; ++i) {
            _tax(0.01 ether);
            vm.warp(block.timestamp + 1200); // one epoch
            assertEq(address(flap).balance, 0.01 ether * (i + 1), "an epoch's tax went missing");
        }

        uint256 fee = flap.schedulerFee();
        vm.deal(STRANGER, fee);
        vm.prank(STRANGER);
        uint256 id = flap.triggerConversion{value: fee}();
        vm.prank(TRIGGER);
        flap.trigger(id);

        assertGt(flap.rewardPool(), 0, "five windows of tax could not be converted");
        // Whatever the pool's depth left unconverted is still free for the next conversion: the
        // failure being ruled out is BNB stranded behind an accounting entry, not BNB still here.
        assertEq(
            flap.freeTax() + flap.reserved(),
            address(flap).balance,
            "tax accumulated out of reach"
        );
    }
}
