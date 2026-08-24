// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {
    VaultUISchema, VaultMethodSchema, FieldDescriptor, ApproveAction
} from "./flap/IVaultSchemasV1.sol";
import {Tournament} from "./Tournament.sol";

/// @title AssayFlapVault
/// @notice The Flap-facing vault: trading tax becomes prize money for verified optimisation work.
///
/// @dev This does not re-implement the tournament. The tournament is already the mechanism of
///      record — it runs the assay, meters the gas and records a score that nobody can dispute —
///      so this contract adds a second, native-BNB reward layer on top of exactly those scores.
///      The same submission therefore earns twice: the ASSAY pot the task was posted with, and a
///      share of whatever the token's trading tax sent here while that task was open.
///
///      Why a separate contract at all: Flap's generic UI reaches a vault, calls
///      `vaultUISchema()` on it, and renders the page from what it finds. A vault is the thing
///      their portal knows how to create and their interface knows how to display, so being one
///      is what puts this protocol on their page instead of only on ours.
///
///      Custody note: BNB that arrives here is assigned to a task the moment that task is
///      endowed, and can only ever leave to an address the tournament has already recorded a
///      score for. There is no owner, no upgrade path, and no sweep of endowed funds.
contract AssayFlapVault is VaultBaseV2 {
    /// @notice The tournament whose verified scores this vault pays against.
    Tournament public immutable tournament;

    /// @notice The tax token this vault belongs to, as told to us by the factory at creation.
    address public immutable taxToken;

    /// @notice Who may endow a task with accumulated BNB. Set at creation to the token's creator.
    address public immutable curator;

    /// @notice BNB assigned to a task's bounty, by task id.
    mapping(uint256 taskId => uint256) public bounty;
    /// @notice BNB already paid out of a task's bounty.
    mapping(uint256 taskId => uint256) public paid;
    /// @notice Whether a miner has taken their share of a task's bounty.
    mapping(uint256 taskId => mapping(address miner => bool)) public collected;

    /// @notice Sum of every task's unpaid bounty. Revenue above this is not yet assigned.
    uint256 public endowed;

    event RevenueReceived(address indexed from, uint256 amount);
    event Endowed(uint256 indexed taskId, uint256 amount, uint256 unassignedLeft);
    event BountyPaid(uint256 indexed taskId, address indexed miner, uint256 amount);

    error NotCurator();
    error NothingUnassigned();
    error TaskNotSettled();
    error NoScore();
    error AlreadyCollected();
    error TransferFailed();

    constructor(Tournament tournament_, address taxToken_, address curator_) {
        tournament = tournament_;
        taxToken = taxToken_;
        curator = curator_;
    }

    /// @notice Trading tax arrives here as native BNB.
    receive() external payable {
        emit RevenueReceived(msg.sender, msg.value);
    }

    // -------------------------------------------------------------------------------------
    // Revenue
    // -------------------------------------------------------------------------------------

    /// @notice BNB that has arrived but is not yet assigned to any task.
    function unassigned() public view returns (uint256) {
        uint256 held = address(this).balance;
        return held > endowed ? held - endowed : 0;
    }

    /// @notice Assigns accumulated revenue to a task's bounty.
    /// @dev Endowing is one-way. Once BNB is behind a task it can only leave to a miner the
    ///      tournament has scored, which is what stops a bounty being announced and then walked
    ///      back once somebody has done the work for it.
    function endow(uint256 taskId, uint256 amount) external {
        if (msg.sender != curator && msg.sender != _getGuardian()) revert NotCurator();
        uint256 free = unassigned();
        if (amount == 0 || amount > free) revert NothingUnassigned();
        bounty[taskId] += amount;
        endowed += amount;
        emit Endowed(taskId, amount, free - amount);
    }

    // -------------------------------------------------------------------------------------
    // Collecting
    // -------------------------------------------------------------------------------------

    /// @notice What `miner` can collect from a task's BNB bounty right now.
    function collectable(uint256 taskId, address miner) public view returns (uint256) {
        if (collected[taskId][miner]) return 0;
        uint256 pot = bounty[taskId];
        if (pot == 0) return 0;

        (, , , uint128 score, , ) = tournament.submissions(taskId, miner);
        if (score == 0) return 0;
        (, , , , , , , uint256 totalScore, ) = tournament.tasks(taskId);
        if (totalScore == 0) return 0;
        return (pot * score) / totalScore;
    }

    /// @notice Pays a scoring miner their share of a task's BNB bounty.
    /// @dev Shares use the tournament's own recorded score, so the split here is the split there.
    function collect(uint256 taskId) external returns (uint256 amount) {
        (, , uint64 revealEnd, , , , , , ) = tournament.tasks(taskId);
        if (block.timestamp < revealEnd) revert TaskNotSettled();
        if (collected[taskId][msg.sender]) revert AlreadyCollected();

        amount = collectable(taskId, msg.sender);
        if (amount == 0) revert NoScore();

        collected[taskId][msg.sender] = true;
        paid[taskId] += amount;
        endowed -= amount;

        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit BountyPaid(taskId, msg.sender, amount);
    }

    // -------------------------------------------------------------------------------------
    // Paginated views — the shape a card list is rendered from
    // -------------------------------------------------------------------------------------

    struct BountyCard {
        uint256 taskId;
        uint256 baselineGas;
        uint256 bountyBnb;
        uint256 paidBnb;
        uint256 entrants;
        uint256 phase;
        uint256 endsAt;
        uint256 yourScore;
        uint256 yourBnb;
    }

    /// @notice One page of tasks with their BNB bounties, newest first.
    function getBounties(address you, uint256 offset, uint256 limit)
        external
        view
        returns (BountyCard[] memory page)
    {
        uint256 total = tournament.taskCount();
        if (offset >= total) return new BountyCard[](0);
        uint256 n = total - offset;
        if (n > limit) n = limit;
        page = new BountyCard[](n);

        for (uint256 i; i < n; ++i) {
            uint256 id = total - offset - i;
            (
                ,
                uint64 commitEnd,
                uint64 revealEnd,
                ,
                uint32 baselineGas,
                ,
                ,
                ,
            ) = tournament.tasks(id);
            (, , , uint128 score, , ) = tournament.submissions(id, you);
            page[i] = BountyCard({
                taskId: id,
                baselineGas: baselineGas,
                bountyBnb: bounty[id],
                paidBnb: paid[id],
                entrants: tournament.scorers(id).length,
                phase: block.timestamp < commitEnd ? 0 : block.timestamp < revealEnd ? 1 : 2,
                endsAt: block.timestamp < commitEnd ? commitEnd : revealEnd,
                yourScore: score,
                yourBnb: collectable(id, you)
            });
        }
    }

    // -------------------------------------------------------------------------------------
    // VaultBase
    // -------------------------------------------------------------------------------------

    /// @notice Live status line, polled by the UI as a banner.
    function description() public view override returns (string memory) {
        if (tournament.taskCount() == 0) return "No task has been posted yet.";
        if (unassigned() > 0) return "Trading tax has accumulated and is waiting to be put behind a task.";
        if (endowed > 0) return "A bounty is live. Beat the gas baseline to earn a share of it.";
        return "All bounties have been collected.";
    }

    // -------------------------------------------------------------------------------------
    // Self-describing UI
    // -------------------------------------------------------------------------------------

    /// @notice Describes this vault's interactive surface so a generic UI can render it.
    /// @dev The pairing that produces cards with buttons: `getBounties` returns an array, and
    ///      `collect` sits beside it as the action on each row. `getMiners` does the same for the
    ///      leaderboard. A schema of scalar views alone renders as one flat column of numbers.
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "AssayVault";
        schema.description = unicode"Trading tax becomes prize money for verified gas-optimisation work. Miners submit EVM runtime bytecode; the chain deploys it, runs every test vector and reads the meter. / 交易税变成可验证优化工作的奖金。矿工提交 EVM 运行时字节码,链把它部署、跑完全部测试向量、读取计量表。";
        schema.methods = new VaultMethodSchema[](4);

        // 0 — the bounty cards.
        VaultMethodSchema memory m = schema.methods[0];
        m.name = "getBounties";
        m.description = unicode"Every task and its BNB bounty, newest first / 全部任务及其 BNB 赏金,最新在前";
        m.inputs = new FieldDescriptor[](3);
        m.inputs[0] = FieldDescriptor("you", "address", unicode"Miner address / 矿工地址", 0);
        m.inputs[1] = FieldDescriptor("offset", "uint256", unicode"Skip / 跳过", 0);
        m.inputs[2] = FieldDescriptor("limit", "uint256", unicode"Page size / 每页数量", 0);
        m.outputs = new FieldDescriptor[](9);
        m.outputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.outputs[1] = FieldDescriptor("baselineGas", "uint256", unicode"Baseline to beat / 要跑赢的基准", 0);
        m.outputs[2] = FieldDescriptor("bountyBnb", "uint256", unicode"BNB bounty / BNB 赏金", 18);
        m.outputs[3] = FieldDescriptor("paidBnb", "uint256", unicode"Already paid / 已支付", 18);
        m.outputs[4] = FieldDescriptor("entrants", "uint256", unicode"Scoring miners / 有得分的矿工", 0);
        m.outputs[5] = FieldDescriptor("phase", "uint256", unicode"0 commit, 1 reveal, 2 settled / 0 承诺 1 揭示 2 已结算", 0);
        m.outputs[6] = FieldDescriptor("endsAt", "time", unicode"Phase ends / 本阶段结束", 0);
        m.outputs[7] = FieldDescriptor("yourScore", "uint256", unicode"Your score / 你的得分", 18);
        m.outputs[8] = FieldDescriptor("yourBnb", "uint256", unicode"Collectable now / 现在可领", 18);
        m.approvals = new ApproveAction[](0);
        m.isOutputArray = true;

        // 1 — the button on every card.
        m = schema.methods[1];
        m.name = "collect";
        m.description = unicode"Collect your share of a task's BNB bounty / 领取你在该任务 BNB 赏金中的份额";
        m.inputs = new FieldDescriptor[](1);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;

        // 2 — revenue readout.
        m = schema.methods[2];
        m.name = "unassigned";
        m.description = unicode"Trading tax received but not yet put behind a task / 已收到但尚未投入任务的交易税";
        m.inputs = new FieldDescriptor[](0);
        m.outputs = new FieldDescriptor[](1);
        m.outputs[0] = FieldDescriptor("amount", "uint256", unicode"BNB / BNB", 18);
        m.approvals = new ApproveAction[](0);

        // 3 — putting revenue behind a task.
        m = schema.methods[3];
        m.name = "endow";
        m.description = unicode"Put accumulated tax behind a task, one way (curator) / 把累计的税一次性投入某个任务(策展方)";
        m.inputs = new FieldDescriptor[](2);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.inputs[1] = FieldDescriptor("amount", "uint256", unicode"BNB to commit / 投入的 BNB", 18);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;
    }
}
