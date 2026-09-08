// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Stack} from "../script/Stack.sol" ;
import {Guardians} from "./Guardians.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {TaskGenerator} from "../src/TaskGenerator.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";

/// @notice The two ways somebody other than a miner could take the pool.
///
/// @dev Both were reachable on the packaged code and neither had a test. `fundTaskFromPool` is
///      unpermissioned on purpose — it moves money the pool already owes to whichever task is
///      running, so there is no decision in it to protect. What it was missing is that a task has
///      to still be running: scores on a settled task are final, so funding one after the fact
///      hands the pool to whoever already holds a score on it.
contract PoolDrainTest is BaseTest {
    address internal constant BTCB = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8;
    address internal constant TAXPAYER = address(0x7A);
    // A legitimate, enrolled miner. That is the threat model: the drain needs a real score, so
    // the person who can run it is somebody already playing, not an outsider.
    address internal constant ATTACKER = ALICE;
    uint256 internal constant ATTACKER_AGENT = AGENT_ALICE;

    AssayFlapVault internal flap;
    address internal guardian;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        flap = Stack.newFlapVault(Guardians.TESTNET, tournament, address(token), Stack.newPriceGuard(Guardians.TESTNET));
        guardian = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    }

    /// @dev Fills the pool without putting it behind any task.
    function _fillPool(uint256 bnb) internal returns (uint256) {
        vm.deal(TAXPAYER, bnb);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: bnb}("");
        require(ok, "tax transfer failed");

        uint256 cap = flap.maxConvertible();
        uint256 amount = bnb > cap ? cap : bnb;
        // The quote is read before the prank: a view call in an argument list consumes it.
        uint256 floor_ = (flap.quote(amount) * 99) / 100;
        vm.prank(guardian);
        flap.endow(amount, floor_);
        return flap.rewardPool();
    }

    /// @dev Leaves `miner` holding a final, non-zero score on the setUp task, which nobody funded.
    function _settleWithAScore(address miner, uint256 agentId) internal {
        _enroll(miner, agentId);
        _commit(miner, agentId, Bytecode.padded(), bytes32(agentId));
        vm.warp(commitEnd + 1);
        _reveal(miner, Bytecode.padded(), bytes32(agentId));
        vm.warp(revealEnd + 1);
    }

    // ------------------------------------------------------------ funding a settled task

    /// @dev The drain. Break the gate in AssayFlapVault.fundTaskFromPool and this passes the
    ///      revert check by never reverting, then shows the attacker holding the whole pool.
    function test_ASettledTaskCannotBeFundedAndCollectedAtOnce() public {
        _settleWithAScore(ATTACKER, ATTACKER_AGENT);

        uint256 pool = _fillPool(0.05 ether);
        assertGt(pool, 0, "the pool has to hold something for this to be a drain");
        assertEq(flap.bounty(drawnTaskId), 0, "the task under attack was never funded");

        // Scores are already final here, so funding now would divide a pot among people who are
        // done competing for it — and this miner is the only one of them.
        vm.prank(ATTACKER);
        // The gate names commitment, not settlement: a settled task is past drawnCommitEnd too.
        vm.expectRevert(bytes(unicode"Commitment closed / 承诺已截止"));
        flap.fundTaskFromPool(drawnTaskId);

        // And with the money still in the pool there is nothing to collect.
        vm.prank(ATTACKER);
        vm.expectRevert(bytes(unicode"Nothing to collect / 无可领取"));
        flap.collect(drawnTaskId);

        assertEq(flap.rewardPool(), pool, "the pool did not move");
        assertEq(IERC20(BTCB).balanceOf(ATTACKER), 0, "the attacker took nothing");
    }

    /// @dev The same call is the intended one while the task is live, so the gate has to be the
    ///      task's state and not a permission. Without this the fix could be "nobody can fund".
    function test_ALiveTaskStillFunds() public {
        uint256 pool = _fillPool(0.05 ether);
        vm.prank(ATTACKER);
        uint256 funded = flap.fundTaskFromPool(drawnTaskId);
        assertEq(funded, pool, "a live task takes the whole pool");
        assertEq(flap.bounty(drawnTaskId), pool, "and it lands on the bounty");
    }

    // ------------------------------------------------------------ blocking a task with dust

    /// @dev `sponsor` is open to anyone by design. The old one-shot gate asked whether the bounty
    ///      was zero, which let one wei of somebody else's BTCB make a task permanently unfundable.
    ///      Restore that gate and this reverts with "Already funded / 已注资".
    function test_DustSponsorshipCannotBlockPoolFunding() public {
        uint256 pool = _fillPool(0.05 ether);

        deal(BTCB, ATTACKER, 1);
        vm.startPrank(ATTACKER);
        IERC20(BTCB).approve(address(flap), 1);
        flap.sponsor(drawnTaskId, 1);
        vm.stopPrank();

        assertEq(flap.bounty(drawnTaskId), 1, "the dust is on the bounty");

        uint256 funded = flap.fundTaskFromPool(drawnTaskId);
        assertEq(funded, pool, "the pool still moves");
        assertEq(flap.bounty(drawnTaskId), pool + 1, "and it sits alongside the sponsorship");
    }

    // ------------------------------------------------ the reveal window: the field is frozen

    /// @dev The half the first fix missed. Commitment closes at drawnCommitEnd, so across the whole
    ///      reveal window nobody new can enter while the pool could still be moved onto the task.
    ///      Anyone already committed could wait for that window and take a pot no one else could
    ///      still compete for. Point the gate back at drawnRevealEnd and this passes by not reverting.
    function test_ATaskInItsRevealWindowCannotStillBeFunded() public {
        _enroll(ATTACKER, ATTACKER_AGENT);
        _commitDrawn(ATTACKER, ATTACKER_AGENT, drawnTight, bytes32(ATTACKER_AGENT));

        // Past commitment, before settlement: the field is closed, the task is not.
        vm.warp(drawnCommitEnd + 1);
        uint256 pool = _fillPool(0.05 ether);
        assertGt(pool, 0, "the pool has to hold something for this to be worth taking");
        assertLt(block.timestamp, drawnRevealEnd, "still inside the reveal window");

        vm.prank(ATTACKER);
        vm.expectRevert(bytes(unicode"Commitment closed / 承诺已截止"));
        flap.fundTaskFromPool(drawnTaskId);

        assertEq(flap.rewardPool(), pool, "the pool did not move");
    }

    // ------------------------------------------------ a bounty that moves after settlement

    /// @dev `collectable` reads the live bounty as the pot, so a sponsorship landing between two
    ///      equal-scoring miners' collections pays the second more than the first. The gate that
    ///      stops it was written for fundTaskFromPool and not for sponsor. Remove it here and this
    ///      passes by not reverting.
    function test_ASettledTaskCannotBeSponsored() public {
        _fillPool(0.05 ether);
        flap.fundTaskFromPool(drawnTaskId);
        vm.warp(drawnRevealEnd + 1);

        deal(BTCB, ATTACKER, 1e15);
        vm.startPrank(ATTACKER);
        IERC20(BTCB).approve(address(flap), 1e15);
        vm.expectRevert(bytes(unicode"Settled / 已结算"));
        flap.sponsor(drawnTaskId, 1e15);
        vm.stopPrank();
    }

    /// @dev And the same call is still the intended one while the task is live, so the gate is the
    ///      task's state and not a permission.
    function test_ALiveTaskCanStillBeSponsored() public {
        _fillPool(0.05 ether);
        uint256 funded = flap.fundTaskFromPool(drawnTaskId);

        deal(BTCB, ATTACKER, 1e15);
        vm.startPrank(ATTACKER);
        IERC20(BTCB).approve(address(flap), 1e15);
        flap.sponsor(drawnTaskId, 1e15);
        vm.stopPrank();

        assertEq(flap.bounty(drawnTaskId), funded + 1e15, "the sponsorship landed");
    }

    /// @dev Only the newest DRAWN task can be funded — `latestGeneratedTaskId`, not `taskCount()`.
    ///      Without this the caller picks which live task the whole pool lands on, so a miner who
    ///      dominates some other open task points this epoch's converted tax at their own and takes
    ///      it against a score nobody was competing with. Delete the latestGeneratedTaskId check in
    ///      fundTaskFromPool and this stops reverting.
    /// @dev The diversion variant, closed. The audit found that the curator needed no search
    ///      advantage at all: `fundTaskFromPool` used to require the NEWEST task, so posting a fresh
    ///      one while miners were committing to another moved the pool onto it — measured, the
    ///      miners in the task they were working in collected zero.
    ///
    ///      The target is `latestGeneratedTaskId` now, written only when the generator posts. A
    ///      curated task posted after the drawn one is newer and still cannot take the pool, and
    ///      the drawn task keeps its funding regardless of what is posted around it.
    function test_ANewerCuratedTaskCannotDivertThePoolFromTheDrawnOne() public {
        uint256 pool = _fillPool(0.05 ether);
        assertGt(pool, 0, "the pool has to hold something for this to matter");

        vm.startPrank(CURATOR);
        token.approve(address(vault), type(uint256).max);
        uint256 newest = tournament.postTask(
            inputs, expected, Bytecode.verbose(), GAS_CAP,
            uint64(block.timestamp + 1 hours), uint64(block.timestamp + 2 hours), POT
        );
        vm.stopPrank();
        assertEq(newest, tournament.taskCount(), "the curated task is the newest by taskCount");
        assertGt(newest, drawnTaskId, "and it was posted after the drawn one");

        // Newest, live, curator-posted — and it cannot have the pool.
        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Not the drawn task / 非抽取任务"));
        flap.fundTaskFromPool(newest);
        assertEq(flap.rewardPool(), pool, "the pool did not move");

        // The drawn task still takes it, so this is the target's identity and not a freeze.
        uint256 funded = flap.fundTaskFromPool(drawnTaskId);
        assertEq(funded, pool, "the drawn task takes the whole pool");
    }

    /// @dev The whole sequence the third round described, run end to end. Posting is open to
    ///      strangers between epochs on purpose — a lost curator key must not end the tournament —
    ///      and a stranger's task IS the newest one the moment they post it, so requiring the newest
    ///      task did not stop this. Delete the poster check in fundTaskFromPool and this passes the
    ///      revert and shows the attacker holding the pool.
    function test_AStrangerCannotPostATaskAndTakeThePool() public {
        // The gap between epochs, which open posting is allowed in.
        vm.warp(revealEnd + 1);
        assertGe(block.timestamp, tournament.latestRevealEnd(), "we are between epochs");

        uint256 pool = _fillPool(0.05 ether);
        assertGt(pool, 0, "the pool has to hold something for this to be a capture");

        // Fund the stranger so they can escrow a pot of their own. Without this the test fails in
        // setup with ERC20InsufficientBalance and never reaches the assertion — which it did, and
        // it failed identically with the guard removed, so it was proving nothing at all.
        deal(address(token), ATTACKER, uint256(POT) * 2);

        // A stranger posts inside the open-post window, escrowing their own pot.
        vm.startPrank(ATTACKER);
        token.approve(address(vault), type(uint256).max);
        uint256 theirs = tournament.postTask(
            inputs, expected, Bytecode.verbose(), GAS_CAP,
            uint64(block.timestamp + 60), uint64(block.timestamp + 120), POT
        );
        vm.stopPrank();

        assertEq(theirs, tournament.taskCount(), "their task is the newest one");

        // Newest, and still taking commitments — both earlier gates are satisfied.
        (uint64 commitEnd_,,,) = tournament.taskGates(theirs);
        assertLt(block.timestamp, commitEnd_, "and its commit window is open");

        vm.prank(ATTACKER);
        vm.expectRevert(bytes(unicode"Not the drawn task / 非抽取任务"));
        flap.fundTaskFromPool(theirs);

        assertEq(flap.rewardPool(), pool, "the pool did not move");
        assertEq(flap.bounty(theirs), 0, "and their task got none of it");
    }

    /// @dev The old one-shot rule is gone on purpose, and this is why: a second conversion landing
    ///      inside the same still-open commit window has to reach the task its trading produced,
    ///      not roll forward to whichever task happens to be newest whenever it lands. Two separate
    ///      fillings, both while the task is still open, both add to the same bounty.
    function test_ATaskCanBeFundedMoreThanOnceWhileItIsStillOpen() public {
        uint256 first = _fillPool(0.05 ether);
        uint256 funded1 = flap.fundTaskFromPool(drawnTaskId);
        assertEq(funded1, first, "the first filling landed");
        assertEq(flap.bounty(drawnTaskId), first, "and is on the bounty");

        uint256 second = _fillPool(0.05 ether);
        uint256 funded2 = flap.fundTaskFromPool(drawnTaskId);
        assertEq(funded2, second, "the second filling landed too");
        assertEq(flap.bounty(drawnTaskId), first + second, "both are on the bounty now");
    }

    /// @dev A call against an empty pool costs gas and nothing else — it must not consume anything
    ///      that would block a real filling from landing later in the same window.
    function test_CallingAgainOnAnEmptyPoolChangesNothing() public {
        uint256 pool = _fillPool(0.05 ether);
        flap.fundTaskFromPool(drawnTaskId);

        vm.expectRevert(bytes(unicode"Pool is empty / 池中无资金"));
        flap.fundTaskFromPool(drawnTaskId);
        assertEq(flap.bounty(drawnTaskId), pool, "an empty-pool attempt moved something");
    }

    /// @dev The scenario the finding described directly: whoever calls first, for however little
    ///      the pool held at that moment, no longer fixes what the task ends up with. A second,
    ///      much larger conversion landing later in the same still-open window still reaches it.
    function test_AnEarlySmallCallDoesNotCapWhatTheTaskCanStillReceive() public {
        uint256 early = _fillPool(0.001 ether);
        flap.fundTaskFromPool(drawnTaskId);
        assertEq(flap.bounty(drawnTaskId), early, "the early sliver landed alone");

        uint256 later = _fillPool(0.05 ether);
        flap.fundTaskFromPool(drawnTaskId);
        assertEq(
            flap.bounty(drawnTaskId),
            early + later,
            "the later, larger conversion did not roll forward to a future task"
        );
    }

    /// @dev A stranger cannot hold the tax back from the miners. OPEN_POST_MAX_SPAN caps one open
    ///      post at ten minutes, but nothing caps how often somebody posts, so an attacker taking
    ///      the boundary block each cycle keeps the all-tasks high-water mark permanently ahead of
    ///      now. That used to hold the vault's withdrawal shut; the withdrawal is gone, and what is
    ///      behind that mark now is the money's route to miners, which is a worse thing to be able
    ///      to jam. It cannot be jammed: the drawn lane waits on the DRAWN task's own reveal, and
    ///      `fundTaskFromPool` reads `latestGeneratedTaskId` and that task's commit window. Neither
    ///      reads `latestRevealEnd`. Point either of them at it and this test stops getting a task
    ///      to fund.
    function test_AStrangerCannotHoldTheTaxBackFromTheMiners() public {
        uint256 curatorBefore = CURATOR.balance;
        vm.warp(revealEnd + 1);
        assertLe(
            tournament.latestCuratedRevealEnd(), block.timestamp, "our own epoch is closed"
        );

        // Unconverted tax, waiting for a task to be put behind.
        vm.deal(TAXPAYER, 0.02 ether);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: 0.02 ether}("");
        require(ok, "tax transfer failed");

        deal(address(token), ATTACKER, uint256(POT) * 2);
        vm.startPrank(ATTACKER);
        token.approve(address(vault), type(uint256).max);
        tournament.postTask(
            inputs, expected, Bytecode.verbose(), GAS_CAP,
            uint64(block.timestamp + 300), uint64(block.timestamp + 600), POT
        );
        vm.stopPrank();

        assertGt(
            tournament.latestRevealEnd(),
            block.timestamp,
            "the stranger did push the all-tasks mark ahead"
        );

        // The drawn lane opens anyway, because it never asked about that mark.
        _postDrawnFixture();
        uint256 pool = _fillPool(0.02 ether);
        assertGt(pool, 0, "the stranger's post stopped the conversion");

        uint256 funded = flap.fundTaskFromPool(drawnTaskId);
        assertEq(funded, pool, "the stranger's post held the pool off the drawn task");
        assertEq(flap.bounty(drawnTaskId), pool, "and it is not on the bounty");

        // And none of it went anywhere else on the way. The one path that used to take idle tax
        // out to a non-miner is not merely gated now, it is absent — asserted by selector, since
        // this file cannot name a function the vault no longer declares.
        (bool gone,) = address(flap).call(abi.encodeWithSignature("withdrawUnconverted(uint256)", uint256(0)));
        assertFalse(gone, "the withdrawal is still reachable");
        assertEq(CURATOR.balance, curatorBefore, "the tax reached the curator");
    }

    /// @dev The protocol's own fallback poster sits on the stranger side of the funding gate.
    ///
    ///      `TaskGenerator` is deployed infrastructure — a beacon proxy whose implementation the
    ///      Guardian controls — and it exists so the tournament survives the curator going quiet.
    ///      It posts as itself on the drawn lane, and since findings 025/026 that is the ONLY lane
    ///      `fundTaskFromPool` pays. This paragraph described the opposite — a poster whitelist that
    ///      shut the fallback path out of the treasury — and that whitelist is what those findings
    ///      removed, because it routed every converted BTCB to the one account that also authors
    ///      the instance. The task the tax reaches is the one nobody chose.
    ///
    ///      Found while fixing 021 and 024; the audit did not report it. Recorded as a measurement
    ///      rather than a paragraph because it is counterintuitive — the gate was written to keep
    ///      strangers out, and this is not a stranger. What a fallback task can still be paid is a
    ///      pot escrowed at posting and `sponsor`, which is open to anyone; what it cannot be paid
    ///      is the tax this vault exists to convert.
    /// @dev The inversion, asserted from both sides. This test used to say the opposite — that a
    ///      generator-posted task could NEVER be funded — and that was the defect, not the design:
    ///      it meant the only task whose instance nobody chose was the only task the tax could not
    ///      pay, while the only task the tax could pay was authored by the account collecting it.
    ///
    ///      Now the drawn task is the fundable one and a curated task is not, so the account that
    ///      chooses an instance and the account that can be paid for solving it are different by
    ///      construction rather than by anybody's restraint.
    function test_OnlyTheDrawnTaskCanBeFundedFromThePool() public {
        uint256 pool = _fillPool(0.05 ether);
        assertGt(pool, 0, "the pool must hold something for this to mean anything");

        // The curated fixture task is live and its commit window is open — and it cannot be funded.
        (uint64 curatedCommitEnd,,,) = tournament.taskGates(taskId);
        assertGt(uint256(curatedCommitEnd), block.timestamp, "the curated task is still open");
        vm.expectRevert(bytes(unicode"Not the drawn task / 非抽取任务"));
        flap.fundTaskFromPool(taskId);

        // The drawn one takes it.
        (,,, address poster) = tournament.taskGates(drawnTaskId);
        assertEq(poster, address(generator), "the drawn task was posted by the generator itself");
        uint256 funded = flap.fundTaskFromPool(drawnTaskId);
        assertEq(funded, pool, "the drawn task takes the whole pool");
        assertEq(flap.bounty(drawnTaskId), pool, "and it lands on its bounty");
    }

    /// @dev The rounding finding, quantified rather than argued. Floor division in
    ///      `(pot * score) / totalScore` performs exactly one division per scoring miner and each
    ///      loses strictly under one wei, so the undistributed remainder is under `scorers` wei.
    ///      That bound holds for any number of miners and is what this test asserts.
    ///
    ///      We first described it as "single-digit wei", and the challenge was right to refuse that:
    ///      nothing caps how many miners may score, so a figure that assumed a handful of them was
    ///      not derivable from the source. The N-independent statement is the one above — under one
    ///      wei each — and it is the arithmetic itself, not an estimate of turnout. What turnout
    ///      changes is only the multiplier, and each additional scorer must pay for an enrolment, a
    ///      commitment and a reveal to add its one wei of dust to an eighteen-decimal token.
    ///
    ///      It is deliberately NOT fixed. Paying the remainder to whoever collects last would make
    ///      an equal-score payout depend on collection order, which is exactly what an earlier round
    ///      of this audit asked us to remove from `collect`, and the dust is worth far less than
    ///      that property.
    function test_TheRoundingDustIsBoundedByTheNumberOfScorers() public {
        uint256 pool = _fillPool(0.05 ether);
        flap.fundTaskFromPool(drawnTaskId);
        assertEq(flap.bounty(drawnTaskId), pool, "the task holds the pool");

        address[3] memory miners = [ALICE, BOB, CAROL];
        uint256[3] memory agents = [AGENT_ALICE, AGENT_BOB, AGENT_CAROL];
        for (uint256 i; i < miners.length; ++i) {
            _enroll(miners[i], agents[i]);
            _commitDrawn(miners[i], agents[i], drawnTight, bytes32(agents[i]));
        }
        vm.warp(drawnCommitEnd + 1);
        for (uint256 i; i < miners.length; ++i) {
            _revealDrawn(miners[i], drawnTight, bytes32(agents[i]));
        }
        vm.warp(drawnRevealEnd + 1);

        uint256 paidOut;
        uint256 scorers;
        for (uint256 i; i < miners.length; ++i) {
            uint256 due = flap.collectable(drawnTaskId, miners[i]);
            if (due == 0) continue;
            scorers++;
            vm.prank(miners[i]);
            paidOut += flap.collect(drawnTaskId);
        }
        assertGt(scorers, 0, "nobody scored; this measures nothing");

        uint256 dust = flap.bounty(drawnTaskId) - paidOut;
        assertLe(dust, scorers, "the remainder exceeded one wei per scoring miner");
    }
}
