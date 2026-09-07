// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";

/// @notice What finding 027's second half actually costs, measured rather than argued.
///
/// @dev We answered that half "Acknowledged", and an Acknowledged is only worth anything if the
///      thing being accepted is written down as something that fails when it stops being true. This
///      file is that. It asserts three things:
///
///        the freeze is real and repeatable;
///        the protocol running normally produces it with no attacker at all;
///        and nothing is stranded by it — conversions continue, bounties still pay, and the
///        Guardian's hatch is untouched.
///
///      The third is the whole basis of the decision. If a future change makes a frozen withdrawal
///      also stop conversions, this stops being an acceptable cost and this file says so.
///
///      Why no fix ships: the obvious one — hold the withdrawal only for a FUNDED drawn epoch —
///      reads `bounty[]`, and `bounty[]` has two writers. `fundTaskFromPool` is one; `sponsor` at
///      AssayFlapVault.sol:650 is the other, and it is `external`, permissionless, and bounded only
///      by `require(amount > 0)`. One wei of BTCB on each drawn epoch rebuilds the freeze exactly,
///      for 92,273 gas on top of a post the project makes anyway — a fresh `bounty[]` slot every
///      epoch, so it is the cold price every time. That is the same dust-jam
///      primitive this repository already knows — `test_DustSponsorshipCannotBlockPoolFunding`
///      exists because one wei of somebody else's BTCB could make a task permanently unfundable —
///      moved onto a different gate. A gate that reads a value a stranger can write is the shape of
///      finding 025, not a fix for it.
contract WithdrawalFreezeTest is BaseTest {
    address internal constant TAXPAYER = address(0x7A);
    address internal constant STRANGER = address(0x571A);

    AssayFlapVault internal flap;
    address internal guardian;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        flap = new AssayFlapVault(tournament, address(token), CURATOR, new PriceGuard());
        guardian = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    }

    /// @dev BaseTest's setUp posts a drawn task of its own, and the lane is serialised, so every
    ///      test here has to let that epoch close before it can draw. Warping to the mark rather
    ///      than past it also exercises the `>=` boundary these tests are partly about.
    function _laneIsFree() internal {
        vm.warp(uint256(drawnRevealEnd));
        vm.roll(block.number + 1);
    }

    function _tax(uint256 amount) internal {
        vm.deal(TAXPAYER, amount);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: amount}("");
        require(ok, "tax transfer failed");
    }

    /// @dev The freeze, repeated, held by the STRANGER and by nobody else.
    ///
    ///      This test used to start at `_laneIsFree()`, which warps to the drawn task's reveal and
    ///      leaves the fixture's CURATED task — `Base.t.sol:109`, a two-hour window — still holding
    ///      `latestCuratedRevealEnd`. The generator's own windows are `COMMIT_SECONDS +
    ///      REVEAL_SECONDS` = twenty minutes, so every one of the stranger's posts ended well inside
    ///      that mark and never cleared the `>` at `Tournament.sol:373`. All three reverts fired
    ///      because of the curator's own task. The test passed with `generateAndPost` contributing
    ///      nothing, which is the one thing it exists to measure.
    ///
    ///      So it now starts past the curated mark, and asserts on each round that the stranger's
    ///      post is what moved it. Delete `generateAndPost` from the loop and the assertion fails
    ///      rather than the reverts continuing to pass.
    function test_AStrangerKeepsTheWithdrawalShutAcrossEpochs() public {
        // Past the fixture's curated task, so nothing of the project's is holding the gate.
        vm.warp(uint256(tournament.latestCuratedRevealEnd()));
        vm.roll(block.number + 1);
        _tax(0.05 ether);

        // The withdrawal is callable at this instant — both gates are `>=` — which is what makes
        // the reverts below attributable to the stranger rather than to leftover state.
        assertGe(
            block.timestamp,
            uint256(tournament.latestCuratedRevealEnd()),
            "the gate is still shut before the stranger has done anything"
        );

        for (uint256 round; round < 3; ++round) {
            uint64 markBefore = tournament.latestCuratedRevealEnd();

            vm.prank(STRANGER);
            uint256 id = generator.generateAndPost();

            (, uint64 revealEnd,,) = tournament.taskGates(id);
            assertGt(uint256(revealEnd), block.timestamp, "the epoch is not live");
            assertEq(
                uint256(tournament.latestCuratedRevealEnd()),
                uint256(revealEnd),
                "the stranger's drawn post did not move the mark, so it is not what shuts the gate"
            );
            assertGt(
                uint256(tournament.latestCuratedRevealEnd()),
                uint256(markBefore),
                "the mark did not advance this round"
            );

            vm.prank(CURATOR);
            vm.expectRevert(bytes(unicode"Epoch open / 本期未结束"));
            flap.withdrawUnconverted(0);

            // The next epoch is legal at exactly this instant: the drawn lane's own gate is `>=`
            // too, so the griefer never has to skip a block. What the boundary leaves is a
            // same-block ordering race, not a closed gate — the withdrawal also passes at exactly
            // this timestamp, and whoever is ordered first wins it.
            vm.warp(uint256(revealEnd));
            vm.roll(block.number + 1);
        }

        assertGt(flap.freeTax(), 0, "the tax the curator cannot reach is not accumulating");
    }

    /// @dev The other half of that boundary, stated as a test rather than as a claim: at exactly
    ///      `latestCuratedRevealEnd` the withdrawal gate PASSES. So "held shut indefinitely" costs
    ///      the griefer winning an ordering race in each boundary block, not merely paying gas —
    ///      and the response to the auditor says so instead of claiming a closed gate.
    function test_AtTheBoundaryTheWithdrawalIsCallable() public {
        vm.warp(uint256(tournament.latestCuratedRevealEnd()));
        vm.roll(block.number + 1);
        _tax(0.05 ether);

        vm.prank(STRANGER);
        uint256 id = generator.generateAndPost();
        (, uint64 revealEnd,,) = tournament.taskGates(id);

        // Exactly the instant the epoch ends — the drawn lane would accept a fresh post here.
        vm.warp(uint256(revealEnd));

        uint256 before = CURATOR.balance;
        vm.prank(CURATOR);
        uint256 sent = flap.withdrawUnconverted(0);
        assertGt(sent, 0, "the boundary block is not open to the withdrawal after all");
        assertEq(CURATOR.balance - before, sent, "the tax did not reach the curator");
    }

    /// @dev And no attacker is required. This is `script/PostTask.s.sol`'s own loop — draw, then
    ///      fund — and it shuts the withdrawal for the whole epoch by itself. Worth pinning because
    ///      it decides how the finding should be read: what a griefer adds is keeping it shut in the
    ///      one state where it would otherwise open, which is when the protocol has stopped running.
    function test_TheProtocolsOwnLoopShutsItToo() public {
        _laneIsFree();
        _tax(0.05 ether);

        uint256 id = generator.generateAndPost();
        (, uint64 revealEnd,,) = tournament.taskGates(id);

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Epoch open / 本期未结束"));
        flap.withdrawUnconverted(0);

        // It opens once nothing of ours is live and nobody draws again. The mark is the maximum
        // over curated AND drawn posts, so the drawn task's own reveal is not enough while the
        // fixture's curated task still runs — waiting on the mark rather than on one task's reveal
        // is what the gate actually does.
        assertGe(
            uint256(tournament.latestCuratedRevealEnd()),
            uint256(revealEnd),
            "the drawn reveal is the whole mark; this test is not measuring what it claims"
        );
        vm.warp(uint256(tournament.latestCuratedRevealEnd()));
        uint256 before = CURATOR.balance;
        vm.prank(CURATOR);
        uint256 sent = flap.withdrawUnconverted(0);
        assertGt(sent, 0, "the withdrawal never opens even with the lane idle");
        assertEq(CURATOR.balance - before, sent, "the tax did not reach the curator");
    }

    /// @dev The basis of the decision: a frozen withdrawal strands nothing.
    ///
    ///      `triggerConversion` carries no epoch gate, so tax keeps becoming BTCB while the
    ///      withdrawal is shut — it reaches miners instead of the curator, which is the direction
    ///      this protocol exists to move it. What the curator loses is the claim on tax from windows
    ///      nobody mined, not the money's existence.
    function test_AFrozenWithdrawalDoesNotStopConversions() public {
        _laneIsFree();
        _tax(0.20 ether);

        vm.prank(STRANGER);
        generator.generateAndPost();

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Epoch open / 本期未结束"));
        flap.withdrawUnconverted(0);

        // The conversion path is open to anyone in exactly that state.
        uint256 fee = flap.schedulerFee();
        vm.deal(STRANGER, fee);
        vm.prank(STRANGER);
        uint256 requestId = flap.triggerConversion{value: fee}();
        assertGt(requestId, 0, "a frozen withdrawal also stopped the conversion chain");
    }

    /// @dev And the Guardian's hatch is untouched by the freeze, so the tax is never beyond reach —
    ///      it is beyond the CURATOR's reach, which is the accurate statement of the cost.
    function test_TheGuardiansHatchIsUnaffected() public {
        _laneIsFree();
        _tax(0.05 ether);

        vm.prank(STRANGER);
        generator.generateAndPost();

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Epoch open / 本期未结束"));
        flap.withdrawUnconverted(0);

        address safe = makeAddr("flapSafe");
        vm.prank(guardian);
        flap.emergencyWithdrawNative(safe);
        assertGt(safe.balance, 0, "the Guardian could not reach the tax either");
    }
}
