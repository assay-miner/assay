// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Stack} from "../script/Stack.sol" ;
import {Guardians} from "./Guardians.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";

/// @notice Whether an epoch's own trading tax reaches that epoch's own task.
///
/// @dev It now does, and `MIN_COMMIT_SPAN` is why. `CONVERSION_INTERVAL` is five minutes and
///      `fundTaskFromPool` refuses once a task's commit window has closed, so a window shorter than
///      that interval lets the rate limit alone decide that an epoch's tax misses that epoch's task.
///      The shipped spec gave a task sixty seconds — a fifth of one conversion period — so four
///      tasks in five could never be funded from tax at all.
///
///      We answered that once by calling it a relationship between two operator-chosen numbers
///      rather than a defect, and the audit was right to refuse it: `script/GenTask.s.sol` rewrites
///      `tasks/epoch.json` from scratch every epoch, so the sixty was not a deployment setting
///      somebody could correct once. It was regenerated into every task the machine posted.
///
///      It is a contract constant now. `postTask` will not accept a window shorter than the
///      cadence, so the shipped tooling cannot reintroduce the gap and neither can anyone else's.
///      `test_MinCommitSpanCoversTheConversionCadence` ties the two constants together across the
///      two contracts that hold them, which is the only thing connecting them.
contract PoolTimingTest is BaseTest {
    address internal constant TAXPAYER = address(0x7A);

    AssayFlapVault internal flap;
    address internal guardian;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        flap = Stack.newFlapVault(Guardians.TESTNET, tournament, address(token), CURATOR, Stack.newPriceGuard(Guardians.TESTNET));
        guardian = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    }

    function _post(uint64 commitSpan, uint64 revealSpan) internal returns (uint256 taskId) {
        vm.startPrank(CURATOR);
        token.approve(address(vault), type(uint256).max);
        taskId = tournament.postTask(
            inputs, expected, Bytecode.verbose(), GAS_CAP,
            uint64(block.timestamp) + commitSpan, uint64(block.timestamp) + commitSpan + revealSpan, POT
        );
        vm.stopPrank();
    }

    /// @dev The configuration that produced findings 021 and 024 can no longer be created.
    ///
    ///      `tasks/epoch.json` carried `commitSeconds: 60` against a 300-second cadence, so a
    ///      conversion armed at posting could not execute until after that task's own commit window
    ///      had shut. This test used to reproduce exactly that and assert the refusal. The window is
    ///      now refused at the source instead: a curated task whose commit window is shorter than
    ///      the cadence cannot be posted at all, so there is no longer a state in which the rate
    ///      limit alone decides that an epoch's tax missed that epoch's task.
    function test_AWindowShorterThanTheCadenceCannotBePostedAtAll() public {
        uint64 shippedCommitSeconds = 60;
        assertLt(
            shippedCommitSeconds,
            flap.CONVERSION_INTERVAL(),
            "the shipped window is no longer shorter than the cadence; this test is stale"
        );

        vm.startPrank(CURATOR);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes(unicode"Commit window too short / 承诺窗口过短"));
        tournament.postTask(
            inputs, expected, Bytecode.verbose(), GAS_CAP,
            uint64(block.timestamp) + shippedCommitSeconds,
            uint64(block.timestamp) + shippedCommitSeconds + 60,
            POT
        );
        vm.stopPrank();
    }

    /// @dev And the spec the ops flow actually posts satisfies it. `script/GenTask.s.sol` writes
    ///      this number into a fresh `tasks/epoch.json` every epoch, so it is the value that reaches
    ///      every live task — not a deployment setting anyone gets to correct once.
    function test_TheShippedSpecSatisfiesTheFloor() public {
        uint64 shipped = 600; // script/GenTask.s.sol: '"commitSeconds": 600'
        assertGe(shipped, tournament.MIN_COMMIT_SPAN(), "the shipped spec cannot be posted");

        uint256 taskId = _post(shipped, 60);
        assertEq(taskId, tournament.taskCount(), "the shipped spec posts");
    }

    /// @dev The behaviour the floor now guarantees, kept as a direct measurement. An attempt
    ///      against an empty pool reverts on `amount > 0` and consumes nothing, so a window still
    ///      open when the conversion lands is funded by a later call. This used to be described as
    ///      a mitigation the shipped config declined to use — it is what every curated task gets.
    function test_AWindowAsWideAsTheCadenceStillCatchesTheConversion() public {
        uint64 wideCommitSeconds = uint64(300 + 60); // one full cadence, plus room to call

        uint256 taskId = _post(wideCommitSeconds, 60);

        vm.expectRevert(bytes(unicode"Pool is empty / 池中无资金"));
        flap.fundTaskFromPool(drawnTaskId);

        vm.warp(block.timestamp + flap.CONVERSION_INTERVAL());
        vm.deal(TAXPAYER, 0.05 ether);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: 0.05 ether}("");
        require(ok, "tax transfer failed");
        uint256 floor_ = (flap.quote(0.05 ether) * 99) / 100;
        vm.prank(guardian);
        flap.endow(0.05 ether, floor_);

        (uint64 commitEnd_,,,) = tournament.taskGates(taskId);
        assertLt(block.timestamp, commitEnd_, "the window closed before the conversion landed");

        uint256 funded = flap.fundTaskFromPool(drawnTaskId);
        assertGt(funded, 0, "the wider window still could not catch its own epoch's tax");
    }

    /// @dev The gate for findings 021 and 024, which are one defect.
    ///
    ///      A task may only be handed the pool while its commit window is open; the conversions
    ///      that fill the pool are rate-limited to one per CONVERSION_INTERVAL. If the window is
    ///      shorter than the interval, the rate limit alone can decide that an epoch's tax misses
    ///      that epoch's task — and the shipped spec's sixty seconds against a five-minute interval
    ///      meant four tasks in five could never be funded from tax at all.
    ///
    ///      The two constants live in different contracts, so nothing but this assertion connects
    ///      them. Lower MIN_COMMIT_SPAN, or raise CONVERSION_INTERVAL, and the gap reopens silently
    ///      with every other test still green. That is exactly how it survived the round in which
    ///      it was reported fixed.
    function test_MinCommitSpanCoversTheConversionCadence() public view {
        assertGe(
            uint256(tournament.MIN_COMMIT_SPAN()),
            flap.CONVERSION_INTERVAL(),
            "a task's commit window can be shorter than the conversion rate limit"
        );
    }

    /// @dev The other half: an open post must still be constructible under the new floor. A minimum
    ///      commit span longer than the maximum span a stranger may claim would leave the fallback
    ///      path with no legal window at all — closing 021 by bricking the thing 023 is about.
    function test_TheOpenPostFallbackStillHasALegalWindow() public view {
        assertLt(
            uint256(tournament.MIN_COMMIT_SPAN()),
            uint256(tournament.OPEN_POST_MAX_SPAN()),
            "no open post can satisfy both the commit floor and the span ceiling"
        );
    }
}
