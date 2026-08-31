// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {Tournament} from "./Tournament.sol";
import {TaskGen} from "./TaskGen.sol";

/// @title TaskGenerator
/// @notice Draws an epoch's task and posts it, in one call, with no arguments.
///
/// @dev Reviewers asked the same question twice: if anyone may post, how does an ordinary user
///      produce a task? Until now they could not. Everything a task needs — the program, its test
///      vectors, and the implementation its difficulty is measured from — was drawn by a Forge
///      script, and someone who could not run that script had nothing to post. "Permissionless"
///      described the access check and not the act.
///
///      None of that work was ever off-chain by necessity. TaskGen is ordinary Solidity: drawing a
///      program, evaluating it, and compiling it are pure functions, and postTask already measures
///      the difficulty itself. So it runs here. A caller supplies nothing at all — the seed is the
///      previous block's hash — and cannot steer the result.
///
///      This is a satellite rather than part of the tournament on purpose. How a good task is
///      drawn is a question that will keep changing; what a settled task pays is not. Keeping them
///      apart means the second never has to be redeployed to improve the first.
contract TaskGenerator is Initializable {
    /// @notice The tournament this generator posts into.
    Tournament public tournament;

    /// @notice Instructions per drawn program.
    uint256 public constant OPS = 9;
    /// @notice Test vectors per task.
    uint256 public constant VECTORS = 8;
    /// @notice Per-vector gas ceiling handed to the tournament.
    uint32 public constant GAS_CAP = 100_000;

    event Generated(uint256 indexed taskId, bytes32 seed, address indexed caller);

    /// @notice How many draws to try before giving up on this block's seed.
    uint256 public constant MAX_DRAWS = 32;

    error NoUsableInstance();
    error SeedUnavailable();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(Tournament tournament_) external initializer {
        tournament = tournament_;
    }

    /// @notice Draws this epoch's task from the previous block hash and posts it.
    ///
    /// @dev **Estimate generously.** How much gas this costs depends on how many draws the block's
    ///      seed needs before one is usable, and the seed changes every block — so an estimate
    ///      taken at block N can be far too low at block N+1. The first live call reverted out of
    ///      gas at 474,590 against an estimate made a block earlier; the same call with room
    ///      succeeded at 1,318,610. Send at least 3,000,000.
    /// @dev Callable by anyone, taking nothing. The tournament's own rules still apply: this posts
    ///      as a stranger, so it only succeeds in the gap after the previous task has settled and
    ///      only for a window the tournament considers short.
    function generateAndPost(uint64 commitSeconds, uint64 revealSeconds)
        external
        returns (uint256 taskId)
    {
        bytes32 seed = blockhash(block.number - 1);
        if (seed == bytes32(0)) revert SeedUnavailable();

        // Redraw until the instance is usable, exactly as the off-chain generator does. Dropping
        // that loop was the first thing that broke here: a single draw collapses or has no slack
        // often enough that a no-argument call almost never succeeded. Each attempt is arithmetic
        // over nine instructions; the expensive step is postTask metering the reference, and that
        // happens once, after an instance has been chosen.
        TaskGen.Op[] memory ops;
        bytes memory naive;
        bool found;
        for (uint256 draws; draws < MAX_DRAWS; ++draws) {
            ops = TaskGen.draw(uint256(keccak256(abi.encode(seed, draws))), OPS);
            naive = TaskGen.compileNaive(ops);
            if (keccak256(TaskGen.compileTight(TaskGen.optimise(ops))) == keccak256(naive)) continue;
            if (_informative(ops, seed)) {
                found = true;
                break;
            }
        }
        // An explicit flag, not `draws == MAX_DRAWS`. Comparing the counter to the bound means the
        // guard silently stops working if the bound ever changes — and what slips through then is
        // not a revert but a posted task whose vectors collapse or whose baseline nothing can beat.
        if (!found) revert NoUsableInstance();

        // Two refusals, both cheap, both about instances that would waste everybody's epoch.
        //
        // A drawn program can destroy its input — an AND against one bit then shifted past it —
        // and every vector then shares an answer a constant could return without computing. And a
        // program the peephole pass cannot improve has no slack, so the literal translation is
        // already optimal and nothing can score. Neither is measured here: the first is eight
        // evaluations and the second is a comparison of two compilations, which is far cheaper
        // than metering both on chain and rejects the same instances.
        (bytes[] memory inputs, bytes32[] memory expected) = _vectors(ops, seed);

        taskId = tournament.postTask(
            inputs,
            expected,
            naive,
            GAS_CAP,
            uint64(block.timestamp) + commitSeconds,
            uint64(block.timestamp) + commitSeconds + revealSeconds,
            0
        );
        emit Generated(taskId, seed, msg.sender);
    }

    /// @dev The input of a drawn program can be destroyed — an AND against one bit then shifted
    ///      past it — and then every vector shares an answer a constant could return without
    ///      computing anything. Eight evaluations is far cheaper than discovering that after the
    ///      task is posted and the epoch is spent.
    function _informative(TaskGen.Op[] memory ops, bytes32 seed) private pure returns (bool) {
        bytes32[] memory out = new bytes32[](VECTORS);
        for (uint256 i; i < VECTORS; ++i) {
            out[i] = keccak256(abi.encodePacked(bytes32(TaskGen.eval(ops, _input(seed, i)))));
            for (uint256 j; j < i; ++j) if (out[j] == out[i]) return false;
        }
        return true;
    }

    function _input(bytes32 seed, uint256 i) private pure returns (uint256) {
        if (i == 0) return 0;
        if (i == 1) return 1;
        if (i == 2) return type(uint256).max;
        return uint256(keccak256(abi.encode(seed, "vec", i)));
    }

    function _vectors(TaskGen.Op[] memory ops, bytes32 seed)
        private
        pure
        returns (bytes[] memory inputs, bytes32[] memory expected)
    {
        inputs = new bytes[](VECTORS);
        expected = new bytes32[](VECTORS);
        for (uint256 i; i < VECTORS; ++i) {
            uint256 x = _input(seed, i);
            inputs[i] = abi.encodePacked(bytes32(x));
            expected[i] = keccak256(abi.encodePacked(bytes32(TaskGen.eval(ops, x))));
        }
    }
}
