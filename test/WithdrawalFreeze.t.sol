// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Stack} from "../script/Stack.sol" ;
import {Guardians} from "./Guardians.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {TaskGen} from "../src/TaskGen.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";

/// @notice Where idle native tax goes now that no function carries it out to us.
///
/// @dev This file used to be about `withdrawUnconverted`: the freeze on it, a stranger holding that
///      gate shut across epochs, the ordering race at its boundary, and the argument that a frozen
///      withdrawal stranded nothing. Flap's review answered the question a level up from the gate —
///      vault funds must not be transferred to a centralized address at all, and an emergency exit
///      must go through their Guardian. So the function, the `curator` destination it paid, the
///      event it emitted and the schema entry that advertised it are all gone, and every question
///      this file used to ask about WHEN the curator could be paid has no subject left to ask it
///      of.
///
///      What replaced it is a property, and a property is testable in a way an acknowledged cost
///      never was. Idle tax now has exactly two ways out of this vault. One is the router, on its
///      way to becoming BTCB that `fundTaskFromPool` puts behind the drawn task and `collect` hands
///      to a miner the tournament scored. The other is `emergencyWithdrawNative`, which only Flap's
///      Guardian may call. There is no third, and that is what is asserted here: the absence is
///      pinned at the ABI, one window of tax is followed from the moment it arrives with nothing
///      open — the exact instant the deleted withdrawal used to become callable — all the way into
///      a miner's balance, and neither the curator nor the deployer is a wei better off at the end
///      of it.
///
///      The stranger is still here, because the drawn lane is still public and still permissionless.
///      What changed is what holding it does. Their post no longer shuts a gate somebody wanted
///      open; it IS the task the converted tax is placed behind, and they get none of that tax
///      unless they mine for it like anybody else.
contract IdleTaxHasNoExitTest is BaseTest {
    address internal constant BTCB = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8;
    address internal constant TRIGGER = 0x560E9830926C9e0EB98a59c6b9902383Fc0D9Eb2;
    address internal constant TAXPAYER = address(0x7A);
    address internal constant STRANGER = address(0x571A);

    AssayFlapVault internal flap;
    address internal guardian;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc_testnet"));
        super.setUp();
        flap = Stack.newFlapVault(Guardians.TESTNET, tournament, address(token), Stack.newPriceGuard(Guardians.TESTNET));
        guardian = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    }

    /// @dev Nothing of the project's is open and no epoch is running. `latestCuratedRevealEnd` is
    ///      the maximum over the curated and drawn lanes, so warping to it closes both — and it is
    ///      precisely the mark the deleted withdrawal waited on, which makes this the state the old
    ///      tests called "the gate is open". Tax that arrives here is the tax that used to be
    ///      payable to the curator, so every test below starts from it.
    function _laneIsIdle() internal {
        vm.warp(uint256(tournament.latestCuratedRevealEnd()));
    }

    /// @dev Sizes a conversion to what the pool can actually take. Written this way rather than
    ///      with a literal because the testnet BTCB pair is shallow enough that one whole coin
    ///      moves it well past the impact bound — a hardcoded amount passes on one chain and is
    ///      capped on the other, and the number that decides it is the pool's, not ours.
    function _within(uint256 wanted) internal view returns (uint256) {
        uint256 cap = flap.maxConvertible();
        return wanted > cap ? cap : wanted;
    }

    function _tax(uint256 amount) internal {
        vm.deal(TAXPAYER, amount);
        vm.prank(TAXPAYER);
        (bool ok,) = payable(address(flap)).call{value: amount}("");
        require(ok, "tax transfer failed");
    }

    /// @dev The whole conversion, driven by a STRANGER, because that is who may drive it. Neither
    ///      leg takes a permission and neither takes an open task: `triggerConversion` derives the
    ///      size from the tax that has accrued, and the scheduler executes it. This is the only
    ///      route the tax has that is not the Guardian's hatch, so every test that follows the money
    ///      goes through here.
    function _convertEverything() internal returns (uint256 requestId) {
        uint256 fee = flap.schedulerFee();
        vm.deal(STRANGER, fee);
        vm.prank(STRANGER);
        requestId = flap.triggerConversion{value: fee}();
        require(requestId != 0, "nothing armed");

        // The scheduler's own moment, which the caller above did not choose.
        vm.warp(block.timestamp + flap.CONVERSION_INTERVAL());
        vm.prank(TRIGGER);
        flap.trigger(requestId);
    }

    /// @dev A stranger opening a drawn epoch, and the program that answers it.
    ///
    ///      `_postDrawnFixture` cannot be pranked into this shape — `drawFor` is a public view, so
    ///      the external staticcall consumes the prank before `generateAndPost` is reached — so the
    ///      derivation is inlined. It is the fixture's, unchanged: the same seed the generator will
    ///      read, the same instance, the same optimised compilation that beats the baseline the
    ///      chain measures. A bounty nobody can answer would not measure whether the money reaches
    ///      a miner.
    function _strangerDrawsAnEpoch() internal returns (uint256 id, bytes memory tight) {
        vm.roll(block.number + 1);
        bytes32 seed = blockhash(block.number - 1);
        require(seed != bytes32(0), "fixture needs a real parent blockhash");

        (TaskGen.Op[] memory ops, bool found) = generator.drawFor(seed);
        require(found, "this seed draws no usable instance");

        vm.prank(STRANGER);
        id = generator.generateAndPost();
        require(id == tournament.latestGeneratedTaskId(), "the drawn mark did not advance");

        tight = TaskGen.compileTight(TaskGen.optimise(ops));
    }

    // ------------------------------------------------------------------ the absence, at the ABI

    /// @notice There is no withdrawal and there is no curator on this vault.
    ///
    /// @dev The plainest form of the reviewer's requirement, asserted where re-adding the path
    ///      would trip over it. Both selectors are gone from the implementation, and the vault has
    ///      no fallback for a call to fall into, so both calls revert. Written as raw calls rather
    ///      than as a compile error because a compile error is not a test: this fails if a later
    ///      round puts either one back, whether or not anything else in the suite still names them.
    ///
    ///      The second half is the consequence, which is what the property is actually about. The
    ///      tax is not merely unreachable by that one function — it is still here, in the vault,
    ///      where the conversion path can find it.
    function test_TheVaultHasNoWithdrawalAndNamesNoCurator() public {
        _laneIsIdle();
        _tax(0.05 ether);

        (bool exists,) =
            address(flap).call(abi.encodeWithSignature("withdrawUnconverted(uint256)", uint256(0)));
        assertFalse(exists, "the withdrawal to a project address is back");

        (exists,) = address(flap).call(abi.encodeWithSignature("curator()"));
        assertFalse(exists, "the vault names a curator again");

        assertEq(address(flap).balance, 0.05 ether, "the tax did not stay in the vault");
        assertEq(flap.freeTax(), 0.05 ether, "the conversion path cannot see it");
    }

    // ---------------------------------------------------------- the route that is left, followed

    /// @notice Tax that arrives with nothing open still converts, still becomes a bounty, and is
    ///         still taken by a miner — and none of it touches the curator or the deployer.
    ///
    /// @dev The replacement for the whole freeze argument, stated forwards instead of backwards.
    ///      The old file measured what the curator could no longer reach and called the money "not
    ///      stranded" on the strength of a conversion call not reverting. That is half a claim: a
    ///      conversion that lands in the pool and stops there is money nobody has, which is the
    ///      thing an auditor was worried about in the first place. So this runs the route to its
    ///      end — arrive, convert, fund, mine, collect — and asserts the two balances that must not
    ///      move while it does.
    ///
    ///      Every leg here is permissionless. A stranger pays the scheduler's fee, the drawn lane
    ///      chooses its own instance, `fundTaskFromPool` names no amount, and `collect` pays whoever
    ///      the tournament scored. Nobody in this test decides where the money goes, which is the
    ///      point of the reviewer's change rather than an incidental property of it.
    function test_IdleTaxConvertsAndAMinerCollectsItWithNothingReachingUs() public {
        _laneIsIdle();

        uint256 curatorBnb = CURATOR.balance;
        uint256 curatorBtcb = IERC20(BTCB).balanceOf(CURATOR);
        uint256 deployerBnb = address(this).balance;

        _tax(_within(0.05 ether));
        uint256 taxIn = address(flap).balance;
        assertGt(taxIn, 0, "there is no tax to follow");

        _convertEverything();
        uint256 pool = flap.rewardPool();
        assertGt(pool, 0, "idle tax did not become BTCB");
        assertEq(address(flap).balance, 0, "native tax was left behind");
        assertEq(IERC20(BTCB).balanceOf(address(flap)), pool, "the BTCB it bought is not here");

        // The next drawn epoch takes the whole pool. Nobody names the task and nobody names the
        // amount — the lane is the one the chain drew and the amount is whatever the pool holds.
        vm.roll(block.number + 1);
        _postDrawnFixture();
        uint256 funded = flap.fundTaskFromPool(drawnTaskId);
        assertEq(funded, pool, "the task did not take the whole pool");
        assertEq(flap.bounty(drawnTaskId), pool, "it did not land as bounty");
        assertEq(flap.rewardPool(), 0, "the pool was not emptied into the task");

        // And a miner takes it.
        _enroll(ALICE, AGENT_ALICE);
        _commitDrawn(ALICE, AGENT_ALICE, drawnTight, bytes32(AGENT_ALICE));
        vm.warp(drawnCommitEnd);
        _revealDrawn(ALICE, drawnTight, bytes32(AGENT_ALICE));
        vm.warp(uint256(drawnRevealEnd) + 1);

        vm.prank(ALICE);
        uint256 got = flap.collect(drawnTaskId);
        assertEq(got, pool, "the sole scorer did not receive the converted tax");
        assertEq(IERC20(BTCB).balanceOf(ALICE), pool, "it did not arrive");
        assertEq(flap.totalPaid(), pool, "the vault's own ledger disagrees with the transfer");

        // Nothing of it reached us at any point along that route.
        assertEq(CURATOR.balance, curatorBnb, "native tax reached the curator");
        assertEq(IERC20(BTCB).balanceOf(CURATOR), curatorBtcb, "converted tax reached the curator");
        assertEq(address(this).balance, deployerBnb, "value reached the deployer");
        assertTrue(flap.solvent(), "the ledger no longer covers what it claims");
    }

    /// @notice A stranger holding the drawn lane cannot strand the tax, because the lane they are
    ///         holding is the route the tax takes.
    ///
    /// @dev What is left of `test_AStrangerKeepsTheWithdrawalShutAcrossEpochs`. The mechanism it
    ///      measured is intact — the drawn lane is public, a stranger's post really does advance
    ///      `latestGeneratedTaskId` and the curated mark, and those assertions are kept here so the
    ///      test still fails if the post stops being what moves them. What is gone is the thing
    ///      that made it a griefing vector: there is no longer a gate on the other side of that
    ///      mark for them to hold shut.
    ///
    ///      So the same act now has the opposite consequence, and this asserts that consequence
    ///      rather than the absence of the old one. The stranger's epoch is the epoch the converted
    ///      tax is placed behind; the stranger scores nothing and can collect nothing; and a miner
    ///      who answers their task takes the whole of it.
    function test_AStrangerHoldingTheLaneCannotStrandTheTax() public {
        _laneIsIdle();
        uint64 markBefore = tournament.latestCuratedRevealEnd();
        uint256 curatorBnb = CURATOR.balance;

        (uint256 id, bytes memory tight) = _strangerDrawsAnEpoch();
        (uint64 commitEnd_, uint64 revealEnd_,,) = tournament.taskGates(id);
        assertGt(uint256(revealEnd_), block.timestamp, "the stranger's epoch is not live");
        assertEq(
            uint256(tournament.latestCuratedRevealEnd()),
            uint256(revealEnd_),
            "the stranger's drawn post did not move the mark, so it is not what holds the lane"
        );
        assertGt(uint256(tournament.latestCuratedRevealEnd()), uint256(markBefore), "the mark did not advance");

        // Tax arrives while they hold it, and converts while they hold it. `triggerConversion`
        // carries no epoch gate and never did — what it used to be measured against was the
        // withdrawal beside it, and there is no withdrawal beside it now.
        _tax(_within(0.05 ether));
        _convertEverything();
        uint256 pool = flap.rewardPool();
        assertGt(pool, 0, "the tax did not convert while a stranger held the lane");

        // Their task is the one the pool pays, and it is still inside its commit window.
        assertLt(block.timestamp, uint256(commitEnd_), "the conversion outran the commit window");
        assertEq(flap.fundTaskFromPool(id), pool, "the stranger's epoch did not take the pool");
        assertEq(flap.bounty(id), pool, "the bounty is not behind their task");

        // Which buys them nothing. They posted; they did not answer.
        _enroll(ALICE, AGENT_ALICE);
        vm.prank(ALICE);
        tournament.commit(id, _commitment(tight, bytes32(AGENT_ALICE), AGENT_ALICE));
        vm.warp(uint256(commitEnd_));
        vm.prank(ALICE);
        tournament.reveal(id, tight, bytes32(AGENT_ALICE));
        vm.warp(uint256(revealEnd_) + 1);

        assertEq(flap.collectable(id, STRANGER), 0, "the lane's occupant has a claim on the bounty");
        vm.prank(ALICE);
        assertEq(flap.collect(id), pool, "the miner who answered did not get the whole bounty");
        assertEq(IERC20(BTCB).balanceOf(STRANGER), 0, "the stranger was paid for holding the lane");
        assertEq(CURATOR.balance, curatorBnb, "native tax reached the curator");
        assertTrue(flap.solvent());
    }

    // ------------------------------------------------------------------ the sanctioned exit

    /// @notice The Guardian's hatch is the one way value leaves here to somebody who did not mine
    ///         for it, and it is the Guardian's alone.
    ///
    /// @dev The reviewer named this path explicitly: if an emergency withdrawal is necessary, it
    ///      goes through Flap's Guardian. That makes the negative half of this test the load-bearing
    ///      half — the curator and a stranger are refused by the same modifier — because a hatch
    ///      anybody could reach would be the removed withdrawal under a different name.
    function test_OnlyTheGuardianMayTakeNativeValueOut() public {
        _laneIsIdle();
        _tax(0.05 ether);

        vm.prank(CURATOR);
        vm.expectRevert(bytes(unicode"Only the guardian / 仅限守护者"));
        flap.emergencyWithdrawNative(CURATOR);

        vm.prank(STRANGER);
        vm.expectRevert(bytes(unicode"Only the guardian / 仅限守护者"));
        flap.emergencyWithdrawNative(STRANGER);

        address safe = makeAddr("flapSafe");
        vm.prank(guardian);
        flap.emergencyWithdrawNative(safe);

        assertEq(safe.balance, 0.05 ether, "the Guardian's hatch did not carry the whole balance");
        assertEq(address(flap).balance, 0, "something was left behind");
    }

    /// @notice And it has no epoch gate, so the state of the tournament can never put the tax
    ///         beyond Flap's reach.
    ///
    /// @dev The surviving half of `test_TheGuardiansHatchIsUnaffected`. The condition it used to be
    ///      measured against — a withdrawal frozen by a live epoch — is gone, but the claim about
    ///      the hatch is not: it is unconditional, and an emergency that arrives mid-epoch is
    ///      exactly the emergency it exists for. A gate added here later would be a gate between
    ///      Flap and the funds the reviewer asked them to be able to reach.
    function test_TheGuardiansHatchHasNoEpochGate() public {
        _laneIsIdle();
        (uint256 id,) = _strangerDrawsAnEpoch();
        _tax(0.05 ether);

        (, uint64 revealEnd_,,) = tournament.taskGates(id);
        assertLt(block.timestamp, uint256(revealEnd_), "the epoch is not live, so this proves nothing");

        address safe = makeAddr("flapSafe");
        vm.prank(guardian);
        flap.emergencyWithdrawNative(safe);
        assertEq(safe.balance, 0.05 ether, "a live epoch held the Guardian's hatch shut");
    }
}
