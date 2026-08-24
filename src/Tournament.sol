// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Crucible} from "./Crucible.sol";
import {AgentRoster} from "./AgentRoster.sol";

/// @title Tournament
/// @notice Gas-optimisation tournaments settled entirely on-chain.
///
/// @dev The mechanism exists to make "agent mining" mean something checkable. A task fixes a
///      behaviour — a set of inputs and the keccak256 of the output each must produce — and a
///      gas baseline. Miners submit raw EVM runtime bytecode. The chain deploys it, runs every
///      vector, and reads the meter. Beating the baseline earns a share of the pot in proportion
///      to how far it was beaten.
///
///      Three properties hold without trusting anybody:
///
///      - Work is hard. Writing bytecode that computes the right answer in less gas than the
///        reference is genuine optimisation effort, and no oracle, committee, or validator set
///        is asked to have an opinion about it.
///      - Verification is cheap. It is N STATICCALLs and a comparison — no consensus round.
///      - Cheating is not available. Only output *hashes* live on-chain, so an answer cannot be
///        copied out of storage; and commitments are sealed before any submission is revealed,
///        so an answer cannot be copied off a competitor either.
contract Tournament {
    using SafeERC20 for IERC20;

    /// @notice Fixed-point base for scores. A submission exactly matching the baseline scores 0;
    ///         one using half the baseline's gas scores 2 * SCORE_SCALE.
    uint256 public constant SCORE_SCALE = 1e18;
    /// @notice Ceiling on a single score, bounding the damage from a mis-specified baseline.
    uint256 public constant MAX_SCORE = 32 * SCORE_SCALE;
    uint256 public constant MAX_VECTORS = 16;
    uint256 public constant MAX_GAS_CAP = 5_000_000;
    /// @notice How long after reveal closes a winner has to claim before the poster may reclaim.
    uint256 public constant CLAIM_WINDOW = 30 days;

    IERC20 public immutable rewardToken;
    AgentRoster public immutable roster;
    address public immutable curator;

    struct Task {
        address poster;
        uint64 commitEnd;
        uint64 revealEnd;
        uint32 gasCap;
        uint32 baselineGas;
        uint128 pot;
        uint128 paidOut;
        uint256 totalScore;
        bool reclaimed;
    }

    struct Submission {
        bytes32 commitment;
        uint64 agentId;
        uint32 gasUsed;
        uint128 score;
        bool revealed;
        bool claimed;
    }

    uint256 public taskCount;
    mapping(uint256 taskId => Task) public tasks;
    mapping(uint256 taskId => Crucible.Vector[]) private _vectors;
    mapping(uint256 taskId => mapping(address miner => Submission)) public submissions;
    /// @notice Append-only list of miners who produced a scoring submission, for leaderboards.
    mapping(uint256 taskId => address[]) private _scorers;

    event TaskPosted(
        uint256 indexed taskId,
        address indexed poster,
        uint32 baselineGas,
        uint32 gasCap,
        uint256 vectorCount,
        uint128 pot,
        uint64 commitEnd,
        uint64 revealEnd
    );
    event Committed(uint256 indexed taskId, address indexed miner, uint256 indexed agentId);
    event Revealed(
        uint256 indexed taskId,
        address indexed miner,
        uint256 indexed agentId,
        address implementation,
        bool passed,
        uint32 gasUsed,
        uint128 score
    );
    event Claimed(uint256 indexed taskId, address indexed miner, uint256 amount);
    event Reclaimed(uint256 indexed taskId, address indexed poster, uint256 amount);

    error NotCurator();
    error NoVectors();
    error TooManyVectors(uint256 count);
    error BadGasCap(uint32 gasCap);
    error BadBaseline();
    error BadWindow();
    error EmptyPot();
    error UnknownTask(uint256 taskId);
    error CommitClosed();
    error AlreadyCommitted();
    error NotInRevealWindow();
    error NothingCommitted();
    error AlreadyRevealed();
    error CommitmentMismatch();
    error RevealNotClosed();
    error NoScore();
    error AlreadyClaimed();
    error ClaimWindowOpen();
    error AlreadyReclaimed();

    constructor(IERC20 rewardToken_, AgentRoster roster_, address curator_) {
        rewardToken = rewardToken_;
        roster = roster_;
        curator = curator_;
    }

    // ---------------------------------------------------------------------------------------
    // Posting
    // ---------------------------------------------------------------------------------------

    /// @notice Publishes a task and escrows its pot.
    /// @dev Curated in this version. Permissionless posting is the ERC-8183 escrow path: a task
    ///      becomes a job, the pot becomes the bounty, and this contract becomes the evaluator
    ///      that signs off delivery. The verification core below does not change to get there.
    /// @param inputs Calldata handed to each submission.
    /// @param expected keccak256 of the return data each corresponding input must produce.
    /// @param baselineGas Total gas the reference implementation spends across all vectors.
    /// @param gasCap Per-vector gas ceiling applied to a submission.
    function postTask(
        bytes[] calldata inputs,
        bytes32[] calldata expected,
        uint32 baselineGas,
        uint32 gasCap,
        uint64 commitEnd,
        uint64 revealEnd,
        uint128 pot
    ) external returns (uint256 taskId) {
        if (msg.sender != curator) revert NotCurator();
        uint256 n = inputs.length;
        if (n == 0 || n != expected.length) revert NoVectors();
        if (n > MAX_VECTORS) revert TooManyVectors(n);
        if (gasCap == 0 || gasCap > MAX_GAS_CAP) revert BadGasCap(gasCap);
        if (baselineGas == 0) revert BadBaseline();
        if (commitEnd <= block.timestamp || revealEnd <= commitEnd) revert BadWindow();
        if (pot == 0) revert EmptyPot();

        taskId = ++taskCount;
        tasks[taskId] = Task({
            poster: msg.sender,
            commitEnd: commitEnd,
            revealEnd: revealEnd,
            gasCap: gasCap,
            baselineGas: baselineGas,
            pot: pot,
            paidOut: 0,
            totalScore: 0,
            reclaimed: false
        });

        Crucible.Vector[] storage v = _vectors[taskId];
        for (uint256 i; i < n; ++i) {
            v.push(Crucible.Vector({input: inputs[i], expected: expected[i]}));
        }

        rewardToken.safeTransferFrom(msg.sender, address(this), pot);
        emit TaskPosted(taskId, msg.sender, baselineGas, gasCap, n, pot, commitEnd, revealEnd);
    }

    // ---------------------------------------------------------------------------------------
    // Commit / reveal
    // ---------------------------------------------------------------------------------------

    /// @notice Seals a submission. `commitment` must be
    ///         `keccak256(abi.encode(runtime, salt, agentId))`.
    /// @dev Binding the agent id into the hash is what stops a bystander from watching a reveal
    ///      in the mempool and racing it: a stolen `(runtime, salt)` pair hashes to a different
    ///      commitment under a different agent id, and commitments are already closed by then.
    function commit(uint256 taskId, bytes32 commitment) external {
        Task storage t = tasks[taskId];
        if (t.poster == address(0)) revert UnknownTask(taskId);
        if (block.timestamp >= t.commitEnd) revert CommitClosed();

        Submission storage s = submissions[taskId][msg.sender];
        if (s.commitment != bytes32(0)) revert AlreadyCommitted();

        uint256 agentId = roster.requireEnrolled(msg.sender);
        s.commitment = commitment;
        s.agentId = uint64(agentId);

        // Keep the stake at risk until this round is fully settled.
        roster.lockUntil(msg.sender, t.revealEnd);
        emit Committed(taskId, msg.sender, agentId);
    }

    /// @notice Opens a sealed submission, runs it, and records its score.
    function reveal(uint256 taskId, bytes calldata runtime, bytes32 salt) external {
        Task storage t = tasks[taskId];
        if (t.poster == address(0)) revert UnknownTask(taskId);
        if (block.timestamp < t.commitEnd || block.timestamp >= t.revealEnd) {
            revert NotInRevealWindow();
        }

        Submission storage s = submissions[taskId][msg.sender];
        if (s.commitment == bytes32(0)) revert NothingCommitted();
        if (s.revealed) revert AlreadyRevealed();
        if (keccak256(abi.encode(runtime, salt, uint256(s.agentId))) != s.commitment) {
            revert CommitmentMismatch();
        }
        s.revealed = true;

        address impl = Crucible.deployRuntime(runtime);
        (bool passed, uint256 gasUsed) =
            Crucible.assay(impl, _vectors[taskId], t.gasCap);

        uint128 score;
        if (passed) {
            s.gasUsed = uint32(gasUsed);
            // The baseline *is* the difficulty. Matching it or doing worse earns nothing.
            if (gasUsed < t.baselineGas) {
                uint256 raw = (uint256(t.baselineGas) * SCORE_SCALE) / gasUsed;
                score = uint128(raw > MAX_SCORE ? MAX_SCORE : raw);
                s.score = score;
                t.totalScore += score;
                _scorers[taskId].push(msg.sender);
            }
        }

        emit Revealed(taskId, msg.sender, s.agentId, impl, passed, s.gasUsed, score);
    }

    // ---------------------------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------------------------

    /// @notice Pays a scoring miner their share of the pot.
    function claim(uint256 taskId) external returns (uint256 amount) {
        Task storage t = tasks[taskId];
        if (t.poster == address(0)) revert UnknownTask(taskId);
        if (block.timestamp < t.revealEnd) revert RevealNotClosed();

        Submission storage s = submissions[taskId][msg.sender];
        if (s.score == 0) revert NoScore();
        if (s.claimed) revert AlreadyClaimed();
        s.claimed = true;

        amount = (uint256(t.pot) * s.score) / t.totalScore;
        t.paidOut += uint128(amount);

        rewardToken.safeTransfer(msg.sender, amount);
        emit Claimed(taskId, msg.sender, amount);
    }

    /// @notice Returns whatever the pot still holds to the poster.
    /// @dev Covers both "nobody beat the baseline" and the integer-division dust left after every
    ///      winner has claimed, so a task can never end with tokens stranded in this contract.
    ///      Available immediately when nothing scored, and after the claim window otherwise.
    function reclaim(uint256 taskId) external returns (uint256 amount) {
        Task storage t = tasks[taskId];
        if (t.poster == address(0)) revert UnknownTask(taskId);
        if (block.timestamp < t.revealEnd) revert RevealNotClosed();
        if (t.reclaimed) revert AlreadyReclaimed();
        if (t.totalScore != 0 && block.timestamp < t.revealEnd + CLAIM_WINDOW) {
            revert ClaimWindowOpen();
        }
        t.reclaimed = true;

        amount = uint256(t.pot) - t.paidOut;
        if (amount != 0) rewardToken.safeTransfer(t.poster, amount);
        emit Reclaimed(taskId, t.poster, amount);
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    function vectorCount(uint256 taskId) external view returns (uint256) {
        return _vectors[taskId].length;
    }

    function vectorAt(uint256 taskId, uint256 i) external view returns (Crucible.Vector memory) {
        return _vectors[taskId][i];
    }

    function scorers(uint256 taskId) external view returns (address[] memory) {
        return _scorers[taskId];
    }

    /// @notice What `claim` would pay right now.
    function pendingReward(uint256 taskId, address miner) external view returns (uint256) {
        Task storage t = tasks[taskId];
        Submission storage s = submissions[taskId][miner];
        if (s.score == 0 || s.claimed || t.totalScore == 0) return 0;
        return (uint256(t.pot) * s.score) / t.totalScore;
    }
}
