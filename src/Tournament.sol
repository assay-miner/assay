// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Crucible} from "./Crucible.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {
    VaultUISchema, VaultMethodSchema, FieldDescriptor, ApproveAction
} from "./flap/IVaultSchemasV1.sol";
import {AgentRoster} from "./AgentRoster.sol";
import {AssayVault} from "./AssayVault.sol";

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
///      Prize money is never held here. Each task's pot lives in `AssayVault`, in an account
///      namespaced to this contract and keyed by task id, so one task can never be paid out of
///      another task's escrow and no operator key can reach any of it.
contract Tournament {
    /// @notice Account namespace for task pots inside the vault.
    bytes32 public constant KIND_POT = "pot";

    /// @notice Fixed-point base for scores.
    /// @dev Scores are quadratic in the gas saved, not a ratio of baseline to gas used. The ratio
    ///      form put every honest submission within a few percent of every other: against a 1656
    ///      baseline, a miner who deleted one redundant opcode to reach 1600 scored 95% of what a
    ///      full search reaching 1520 scored. That pays a person who spots the obvious almost as
    ///      well as a machine that searches, which is the opposite of what this tournament is for.
    ///      Squaring the margin makes being twice as good pay four times as much.
    uint256 public constant SCORE_SCALE = 1e18;
    /// @notice Ceiling on a single score.
    /// @dev Normalising by the square of the baseline puts every score in [0, SCORE_SCALE] by
    ///      construction, so the ceiling is only ever reached by a submission that burned no gas
    ///      at all. It stays as a bound rather than an assertion because a mis-specified baseline
    ///      should cost the task its payout curve, not the contract its arithmetic.
    uint256 public constant MAX_SCORE = SCORE_SCALE;
    uint256 public constant MAX_VECTORS = 16;
    uint256 public constant MAX_GAS_CAP = 5_000_000;
    /// @notice How long after reveal closes a winner has to claim before the poster may reclaim.
    uint256 public constant CLAIM_WINDOW = 30 days;

    /// @notice Longest a task may run, from posting to the close of reveal.
    /// @dev `commit` hands `revealEnd` to `AgentRoster.lockUntil`, which only ever raises the lock
    ///      and has no unlock path. Without a ceiling here, a task posted with a distant
    ///      `revealEnd` locked the stake of everybody who entered it for as long as it liked.
    uint64 public constant MAX_TASK_SPAN = 30 days;

    /// @notice The longest window a task posted by nobody in particular may run for.
    /// @dev Anyone may post once the previous task has settled, which is what keeps the protocol
    ///      running if the curator goes quiet. The project's tax is no longer what this protects:
    ///      the vault's withdrawal waits on `latestCuratedRevealEnd`, which only a curator or
    ///      Guardian post advances. What the cap still bounds is how long one open post can keep
    ///      the next poster out, since `latestRevealEnd` is a high-water mark no later post can
    ///      walk back. A stranger gets ten minutes; the curator and the Guardian keep the full
    ///      range.
    uint64 public constant OPEN_POST_MAX_SPAN = 10 minutes;

    AssayVault public immutable vault;
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

    /// @notice The furthest reveal deadline any task has ever carried, or zero before the first.
    /// @dev The vault gates its withdrawal on this, and it is a high-water mark rather than a
    ///      lookup of the newest task for a reason: a task posted later can close earlier. Reading
    ///      tasks[taskCount].revealEnd meant posting a short task beside a long one moved the
    ///      pointer to the short one, and the gate opened while the long task was still accepting
    ///      reveals — the tax it was protecting could be withdrawn out from under a working miner.
    ///      Monotonic, so no ordering of posts can walk it backwards.
    uint64 public latestRevealEnd;

    /// @notice The same high-water mark, but counting only tasks this project or the Guardian
    ///         published.
    /// @dev The vault's withdrawal used to wait on `latestRevealEnd`, which any stranger can push
    ///      forward by posting. OPEN_POST_MAX_SPAN caps a single open post at ten minutes, and that
    ///      is what makes one post survivable — but nothing caps how often somebody posts. An
    ///      attacker who takes the boundary block each cycle keeps the mark permanently ahead and
    ///      the project can never reclaim tax from windows nobody mined.
    ///
    ///      A stranger's task cannot be funded from the reward pool, so unconverted tax is not
    ///      holding anything up for it. Only our own open task has a claim on waiting, and this is
    ///      the mark that expresses that. Monotonic for the same reason as the one above.
    uint64 public latestCuratedRevealEnd;
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


    constructor(AssayVault vault_, AgentRoster roster_, address curator_) {
        vault = vault_;
        roster = roster_;
        curator = curator_;
    }

    /// @notice The vault account escrowing a task's pot. Anyone can read its balance directly.
    function potAccount(uint256 taskId) public view returns (bytes32) {
        return vault.accountId(address(this), KIND_POT, bytes32(taskId));
    }

    // ---------------------------------------------------------------------------------------
    // Posting
    // ---------------------------------------------------------------------------------------

    /// @notice Publishes a task and escrows its pot.
    /// @dev The curator and the Guardian may post at any time, across the full MAX_TASK_SPAN. A
    ///      stranger may post too, but only in the gap between epochs and only inside
    ///      OPEN_POST_MAX_SPAN, so a lost or compromised curator key cannot end task creation.
    ///      Only a curated post advances `latestCuratedRevealEnd`, so an open post cannot hold the
    ///      vault's withdrawal shut.
    ///
    ///      What is still ahead is the ERC-8183 escrow path: a task
    ///      becomes a job, the pot becomes the bounty, and this contract becomes the evaluator
    ///      that signs off delivery. The verification core below does not change to get there.
    /// @param inputs Calldata handed to each submission.
    /// @param expected keccak256 of the return data each corresponding input must produce.
    /// @param referenceRuntime An implementation that answers these vectors. The chain runs it and
    ///        the gas it costs becomes the baseline, so the difficulty is measured, not asserted.
    /// @param gasCap Per-vector gas ceiling applied to a submission.
    function postTask(
        bytes[] calldata inputs,
        bytes32[] calldata expected,
        bytes calldata referenceRuntime,
        uint32 gasCap,
        uint64 commitEnd,
        uint64 revealEnd,
        uint128 pot
    ) external returns (uint256 taskId) {
        // The Guardian may post too. curator is immutable and this was its only gate, so a lost or
        // compromised key ended task creation permanently — the vault side already had this
        // fallback on every privileged function and the tournament had none at all.
        if (msg.sender != curator && msg.sender != _getGuardian()) {
        // Open posting, but only in the gap between tasks and only for a short window.
        require(block.timestamp >= latestRevealEnd, unicode"Not the curator / 非策展方");
        require(
                uint256(revealEnd) <= block.timestamp + OPEN_POST_MAX_SPAN,
                unicode"Bad window / 时间窗口不合法"
            );
    }
        uint256 n = inputs.length;
        require(n != 0 && n == expected.length, unicode"No vectors / 无测试向量");
        require(n <= MAX_VECTORS, unicode"Too many vectors / 测试向量过多");
        require(gasCap != 0 && gasCap <= MAX_GAS_CAP, unicode"Bad gas cap / gas 上限不合法");
        require(
            commitEnd > block.timestamp && revealEnd > commitEnd
                && uint256(revealEnd) <= block.timestamp + MAX_TASK_SPAN,
            unicode"Bad window / 时间窗口不合法"
        );

        // The difficulty is measured here, not accepted here.
        //
        // It used to arrive as a number and the only check on it was non-zero, so a poster could
        // name any difficulty they liked: a baseline of 1 makes the task unwinnable and pays
        // nobody, and a baseline of 2^32-1 makes a deliberately wasteful submission score. Neither
        // is detectable from the parameters — the contract had nothing to compare them against.
        //
        // It has, though: the same Crucible that settles a reveal can run a reference
        // implementation against these very vectors. So a poster supplies the implementation the
        // baseline is meant to describe, and the chain measures what it costs. That makes the
        // number provably the price of a program that answers the task, and makes the task
        // provably answerable — a reference that fails its own vectors is rejected outright.
        Crucible.Vector[] memory probe = new Crucible.Vector[](n);
        for (uint256 i; i < n; ++i) {
            probe[i] = Crucible.Vector({input: inputs[i], expected: expected[i]});
        }
        (bool referenceOk, uint256 measured) =
            Crucible.assay(Crucible.deployRuntime(referenceRuntime), probe, gasCap);
        require(referenceOk, unicode"Reference fails its own vectors / 参考实现跑不过自己的向量");
        require(measured != 0 && measured <= type(uint32).max, unicode"Bad baseline / 基准不合法");
        uint32 baselineGas = uint32(measured);

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

        if (revealEnd > latestRevealEnd) latestRevealEnd = revealEnd;
        if (
            (msg.sender == curator || msg.sender == _getGuardian())
                && revealEnd > latestCuratedRevealEnd
        ) {
            latestCuratedRevealEnd = revealEnd;
        }

        Crucible.Vector[] storage v = _vectors[taskId];
        for (uint256 i; i < n; ++i) {
            v.push(Crucible.Vector({input: inputs[i], expected: expected[i]}));
        }

        // A pot is optional. The prize this protocol exists to pay is the trading tax the vault
        // converts and books against this same taskId, so a task the project posts carries no
        // escrow at all; a third party who wants to add to it still can, in the same token.
        if (pot != 0) vault.deposit(KIND_POT, bytes32(taskId), msg.sender, pot);
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
        require(t.poster != address(0), unicode"No such task / 该任务不存在");
        require(block.timestamp < t.commitEnd, unicode"Commit window closed / 承诺窗口已关闭");

        Submission storage s = submissions[taskId][msg.sender];
        require(s.commitment == bytes32(0), unicode"Already committed / 已提交承诺");

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
        require(t.poster != address(0), unicode"No such task / 该任务不存在");
        require(
            block.timestamp >= t.commitEnd && block.timestamp < t.revealEnd,
            unicode"Not in the reveal window / 不在揭示窗口内"
        );

        Submission storage s = submissions[taskId][msg.sender];
        require(s.commitment != bytes32(0), unicode"Nothing committed / 没有承诺");
        require(!s.revealed, unicode"Already revealed / 已揭示");
        require(
            keccak256(abi.encode(runtime, salt, uint256(s.agentId))) == s.commitment,
            unicode"Commitment mismatch / 承诺不匹配"
        );
        s.revealed = true;

        address impl = Crucible.deployRuntime(runtime);
        (bool passed, uint256 gasUsed) =
            Crucible.assay(impl, _vectors[taskId], t.gasCap);

        uint128 score;
        if (passed) {
            s.gasUsed = uint32(gasUsed);
            // The baseline *is* the difficulty. Matching it or doing worse earns nothing.
            if (gasUsed < t.baselineGas) {
                uint256 margin = uint256(t.baselineGas) - gasUsed;
                uint256 raw = (margin * margin * SCORE_SCALE) / (uint256(t.baselineGas) * uint256(t.baselineGas));
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
        require(t.poster != address(0), unicode"No such task / 该任务不存在");
        require(block.timestamp >= t.revealEnd, unicode"Reveal not closed / 揭示尚未结束");

        Submission storage s = submissions[taskId][msg.sender];
        require(s.score != 0, unicode"No score / 无得分");
        require(!s.claimed, unicode"Already claimed / 已领取");
        s.claimed = true;

        amount = (uint256(t.pot) * s.score) / t.totalScore;
        t.paidOut += uint128(amount);

        vault.payOut(KIND_POT, bytes32(taskId), msg.sender, amount);
        emit Claimed(taskId, msg.sender, amount);
    }

    /// @notice Returns whatever the pot still holds to the poster.
    /// @dev Covers both "nobody beat the baseline" and the integer-division dust left after every
    ///      winner has claimed, so a task can never end with tokens stranded in this contract.
    ///      Available immediately when nothing scored, and after the claim window otherwise.
    function reclaim(uint256 taskId) external returns (uint256 amount) {
        Task storage t = tasks[taskId];
        require(t.poster != address(0), unicode"No such task / 该任务不存在");
        require(block.timestamp >= t.revealEnd, unicode"Reveal not closed / 揭示尚未结束");
        require(!t.reclaimed, unicode"Already reclaimed / 已回收");
        require(
            t.totalScore == 0 || block.timestamp >= t.revealEnd + CLAIM_WINDOW,
            unicode"Claim window is open / 领取窗口未结束"
        );
        t.reclaimed = true;

        amount = uint256(t.pot) - t.paidOut;
        if (amount != 0) vault.payOut(KIND_POT, bytes32(taskId), t.poster, amount);
        emit Reclaimed(taskId, t.poster, amount);
    }

    // ---------------------------------------------------------------------------------------
    // Paginated views
    //
    // Shaped for a generic, schema-driven UI. A view that returns an array is what turns a page
    // from one flat column of numbers into a list of cards, each with the write method beside it
    // as its button — so these exist as much for the interface as for the reader.
    // ---------------------------------------------------------------------------------------

    struct TaskCard {
        uint256 taskId;
        uint256 baselineGas;
        uint256 gasCap;
        uint256 pot;
        uint256 vectors;
        uint256 entrants;
        uint256 phase; // 0 committing, 1 revealing, 2 settled
        uint256 endsAt;
        uint256 yourScore;
        uint256 yourClaimable;
    }

    struct MinerCard {
        address miner;
        uint256 agentId;
        uint256 gasUsed;
        uint256 score;
        uint256 reward;
    }

    /// @notice One page of tasks, newest first, annotated with what `you` stands to collect.
    function getTasks(address you, uint256 offset, uint256 limit)
        external
        view
        returns (TaskCard[] memory page)
    {
        uint256 total = taskCount;
        if (offset >= total) return new TaskCard[](0);
        uint256 n = total - offset;
        if (n > limit) n = limit;
        page = new TaskCard[](n);

        for (uint256 i; i < n; ++i) {
            uint256 id = total - offset - i; // newest first
            Task storage t = tasks[id];
            Submission storage s = submissions[id][you];
            page[i] = TaskCard({
                taskId: id,
                baselineGas: t.baselineGas,
                gasCap: t.gasCap,
                pot: t.pot,
                vectors: _vectors[id].length,
                entrants: _scorers[id].length,
                phase: block.timestamp < t.commitEnd ? 0 : block.timestamp < t.revealEnd ? 1 : 2,
                endsAt: block.timestamp < t.commitEnd ? t.commitEnd : t.revealEnd,
                yourScore: s.score,
                yourClaimable: (s.score == 0 || s.claimed || t.totalScore == 0)
                    ? 0
                    : (uint256(t.pot) * s.score) / t.totalScore
            });
        }
    }

    /// @notice One page of a task's scoring submissions, best first.
    function getMiners(uint256 taskId, uint256 offset, uint256 limit)
        external
        view
        returns (MinerCard[] memory page)
    {
        address[] storage list = _scorers[taskId];
        if (offset >= list.length) return new MinerCard[](0);
        uint256 n = list.length - offset;
        if (n > limit) n = limit;
        page = new MinerCard[](n);

        Task storage t = tasks[taskId];
        for (uint256 i; i < n; ++i) {
            address m = list[offset + i];
            Submission storage s = submissions[taskId][m];
            page[i] = MinerCard({
                miner: m,
                agentId: s.agentId,
                gasUsed: s.gasUsed,
                score: s.score,
                reward: t.totalScore == 0 ? 0 : (uint256(t.pot) * s.score) / t.totalScore
            });
        }
        // best first
        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (page[j].score > page[i].score) (page[i], page[j]) = (page[j], page[i]);
            }
        }
    }

    /// @notice The token a participant needs to hold. Named for the schema's approval resolver.
    function taxToken() external view returns (address) {
        return address(vault.asset());
    }

    /// @notice Live one-line status, polled by the UI as a banner.
    /// @notice The three fields a gate needs from a task, without decoding the rest of it.
    /// @dev The vault reads task state at seven call sites, each only to decide whether a window
    ///      is open or whether anybody scored. Going through `tasks()` made every one of them
    ///      decode all nine fields, and the vault is the contract with no code size to spare —
    ///      it is embedded whole in the factory, which sits under EIP-170. This returns the three
    ///      that are actually read.
    function taskGates(uint256 taskId)
        external
        view
        returns (uint64 commitEnd, uint64 revealEnd, uint256 totalScore, address poster)
    {
        Task storage t = tasks[taskId];
        return (t.commitEnd, t.revealEnd, t.totalScore, t.poster);
    }

    function description() external view returns (string memory) {
        uint256 n = taskCount;
        if (n == 0) return unicode"No task has been posted yet. / 尚未发布任务。";
        Task storage t = tasks[n];
        if (block.timestamp < t.commitEnd) {
            return unicode"A task is open. Commitments are being taken. / 任务进行中，正在接受提交承诺。";
        }
        if (block.timestamp < t.revealEnd) {
            return unicode"Commitments are closed. Submissions are being revealed and assayed. / 承诺已截止，正在揭示并计量提交。";
        }
        return unicode"The latest task is settled. Winners may claim. / 最新一期已结算，获胜者可领取。";
    }

    // ---------------------------------------------------------------------------------------
    // Dry run
    // ---------------------------------------------------------------------------------------

    /// @notice Runs a candidate against a task's vectors and reports what it would score.
    /// @dev Deliberately NOT `view`: assaying deploys the candidate, and CREATE cannot happen in
    ///      a static context. It is still free — a miner calls it with `eth_call`, which executes
    ///      the same code without mining a transaction, so nothing is written and no gas is paid.
    ///
    ///      This exists so a miner never has to guess. The number returned here is produced by
    ///      the same `Crucible.assay` the settlement path runs, against the same stored vectors,
    ///      so it is the number that will be recorded — not an estimate of it. Guessing is how a
    ///      miner spends a reveal to discover their submission was two gas short.
    ///
    ///      It leaks nothing: the vectors are already public, and knowing your own score does not
    ///      let you see anybody else's sealed commitment.
    function previewAssay(uint256 taskId, bytes calldata runtime)
        external
        returns (bool passed, uint256 gasUsed, uint256 score)
    {
        Task storage t = tasks[taskId];
        require(t.poster != address(0), unicode"No such task / 该任务不存在");

        address impl = Crucible.deployRuntime(runtime);
        (passed, gasUsed) = Crucible.assay(impl, _vectors[taskId], t.gasCap);

        if (passed && gasUsed < t.baselineGas) {
            uint256 margin = uint256(t.baselineGas) - gasUsed;
            uint256 raw = (margin * margin * SCORE_SCALE) / (uint256(t.baselineGas) * uint256(t.baselineGas));
            score = raw > MAX_SCORE ? MAX_SCORE : raw;
        }
    }


    // ---------------------------------------------------------------------------------------
    // Self-describing UI
    // ---------------------------------------------------------------------------------------

    /// @notice Describes this contract's whole interactive surface, on chain.
    ///
    /// @dev A generic UI calls this and renders a working page for a contract it has never seen.
    ///      The shape matters more than the words: a view with `isOutputArray == true` becomes a
    ///      paginated list of cards, and a write method sitting beside it becomes the button on
    ///      each card. `getTasks` + `claim` is that pairing, and so is `getMiners`. A schema of
    ///      scalar views alone would render as one flat column of numbers.
    ///
    ///      `approvals` on `postTask` tells the UI to send the ERC-20 approve first, naming the
    ///      input field that carries the amount, so nobody has to approve by hand.
    function vaultUISchema() external pure returns (VaultUISchema memory schema) {
        schema.vaultType = "AssayTournament";
        schema.description = unicode"Gas-optimisation tournaments settled on chain. Submit EVM runtime bytecode; the chain deploys it, runs every test vector and reads the meter. / 链上结算的 gas 优化锦标赛。提交 EVM 运行时字节码,链把它部署、跑完全部测试向量、读取计量表。";
        schema.methods = new VaultMethodSchema[](7);

        // 0 — task cards. The array view that carries the page.
        VaultMethodSchema memory m = schema.methods[0];
        m.name = "getTasks";
        m.description = unicode"Every task, newest first, with what you stand to collect / 全部任务,最新在前,并显示你能领多少";
        m.inputs = new FieldDescriptor[](3);
        m.inputs[0] = FieldDescriptor("you", "address", unicode"Miner address / 矿工地址", 0);
        m.inputs[1] = FieldDescriptor("offset", "uint256", unicode"Skip / 跳过", 0);
        m.inputs[2] = FieldDescriptor("limit", "uint256", unicode"Page size / 每页数量", 0);
        m.outputs = new FieldDescriptor[](10);
        m.outputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.outputs[1] = FieldDescriptor("baselineGas", "uint256", unicode"Baseline gas to beat / 要跑赢的基准", 0);
        m.outputs[2] = FieldDescriptor("gasCap", "uint256", unicode"Per-vector cap / 单向量上限", 0);
        m.outputs[3] = FieldDescriptor("pot", "uint256", unicode"Prize pot / 奖池", 18);
        m.outputs[4] = FieldDescriptor("vectors", "uint256", unicode"Test vectors / 测试向量", 0);
        m.outputs[5] = FieldDescriptor("entrants", "uint256", unicode"Scoring miners / 有得分的矿工", 0);
        m.outputs[6] = FieldDescriptor("phase", "uint256", unicode"0 commit, 1 reveal, 2 settled / 0 承诺 1 揭示 2 已结算", 0);
        m.outputs[7] = FieldDescriptor("endsAt", "time", unicode"Current phase ends / 本阶段结束", 0);
        m.outputs[8] = FieldDescriptor("yourScore", "uint256", unicode"Your score / 你的得分", 18);
        m.outputs[9] = FieldDescriptor("yourClaimable", "uint256", unicode"Your share, once reveal closes / 你的份额,揭示结束后可领", 18);
        m.approvals = new ApproveAction[](0);
        m.isOutputArray = true;

        // 1 — the button on every task card.
        m = schema.methods[1];
        m.name = "claim";
        m.description = unicode"Collect your share of a settled task / 领取你在已结算任务中的份额";
        m.inputs = new FieldDescriptor[](1);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;

        // 2 — leaderboard cards.
        m = schema.methods[2];
        m.name = "getMiners";
        m.description = unicode"Scoring submissions for a task, best first / 某个任务的得分提交,最优在前";
        m.inputs = new FieldDescriptor[](3);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.inputs[1] = FieldDescriptor("offset", "uint256", unicode"Skip / 跳过", 0);
        m.inputs[2] = FieldDescriptor("limit", "uint256", unicode"Page size / 每页数量", 0);
        m.outputs = new FieldDescriptor[](5);
        m.outputs[0] = FieldDescriptor("miner", "address", unicode"Miner / 矿工", 0);
        m.outputs[1] = FieldDescriptor("agentId", "uint256", unicode"ERC-8004 identity / ERC-8004 身份", 0);
        m.outputs[2] = FieldDescriptor("gasUsed", "uint256", unicode"Gas measured / 实测 gas", 0);
        m.outputs[3] = FieldDescriptor("score", "uint256", unicode"Score / 得分", 18);
        m.outputs[4] = FieldDescriptor("reward", "uint256", unicode"Reward / 奖励", 18);
        m.approvals = new ApproveAction[](0);
        m.isOutputArray = true;

        // 3 — the dry run. Free: the UI reaches it with eth_call.
        m = schema.methods[3];
        m.name = "previewAssay";
        m.description = unicode"Score a candidate for free before committing to it / 承诺之前免费试算一份候选";
        m.inputs = new FieldDescriptor[](2);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.inputs[1] = FieldDescriptor("runtime", "bytes", unicode"EVM runtime bytecode / EVM 运行时字节码", 0);
        m.outputs = new FieldDescriptor[](3);
        m.outputs[0] = FieldDescriptor("passed", "bool", unicode"Answered every vector / 全部向量正确", 0);
        m.outputs[1] = FieldDescriptor("gasUsed", "uint256", unicode"Gas it would meter / 会被计到的 gas", 0);
        m.outputs[2] = FieldDescriptor("score", "uint256", unicode"Score it would earn / 会拿到的得分", 18);
        m.approvals = new ApproveAction[](0);

        // 4 — seal.
        m = schema.methods[4];
        m.name = "commit";
        m.description = unicode"Seal keccak256(runtime, salt, agentId). Nobody can see it until you reveal / 封存 keccak256(字节码, 盐, agentId),揭示前无人看得到";
        m.inputs = new FieldDescriptor[](2);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.inputs[1] = FieldDescriptor("commitment", "bytes32", unicode"Commitment hash / 承诺哈希", 0);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;

        // 5 — open.
        m = schema.methods[5];
        m.name = "reveal";
        m.description = unicode"Open your submission and have it assayed / 揭示你的提交物并接受检定";
        m.inputs = new FieldDescriptor[](3);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.inputs[1] = FieldDescriptor("runtime", "bytes", unicode"EVM runtime bytecode / EVM 运行时字节码", 0);
        m.inputs[2] = FieldDescriptor("salt", "bytes32", unicode"The salt you committed with / 承诺时用的盐", 0);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;

        // 6 — posting a task, with the approve the UI must send first.
        m = schema.methods[6];
        m.name = "postTask";
        m.description = unicode"Publish a task (open window only for non-curators) / 发布一个任务(非策展方仅限开放窗口期)";
        m.inputs = new FieldDescriptor[](7);
        m.inputs[0] = FieldDescriptor("inputs", "bytes[]", unicode"Calldata per vector / 每个向量的调用数据", 0);
        m.inputs[1] = FieldDescriptor("expected", "bytes32[]", unicode"keccak256 of each expected output / 每个期望输出的 keccak256", 0);
        m.inputs[2] = FieldDescriptor(
            "referenceRuntime", "bytes", unicode"Reference implementation; its measured cost becomes the baseline / 参考实现,链上实测其开销作为基准", 0
        );
        m.inputs[3] = FieldDescriptor("gasCap", "uint32", unicode"Per-vector cap / 单向量上限", 0);
        m.inputs[4] = FieldDescriptor("commitEnd", "uint64", unicode"Commitments close / 承诺截止", 0);
        m.inputs[5] = FieldDescriptor("revealEnd", "uint64", unicode"Reveals close / 揭示截止", 0);
        m.inputs[6] = FieldDescriptor("pot", "uint128", unicode"Prize pot / 奖池", 18);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](1);
        m.approvals[0] = ApproveAction("taxToken", "pot");
        m.isWriteMethod = true;
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

    /// @notice The Flap Guardian for this chain, resolved exactly the way VaultBase does.
    /// @dev A constant per chain, so this needs no constructor argument and creates no cycle with
    ///      the vault — which is deployed after this contract and takes it as an argument.
    function _getGuardian() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 56) return 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        if (chainId == 97) return 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        // Zero, not a revert. Reverting would make postTask unusable on any chain Flap has not
        // deployed a Guardian to — including a local one — and this is a fallback, not a
        // requirement: with no Guardian the gate is simply curator-only, which is where it started.
        return address(0);
    }
}
