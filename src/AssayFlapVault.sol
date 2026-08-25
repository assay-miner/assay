// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {IPancakeRouter02} from "./interfaces/IPancakeRouter02.sol";
import {
    VaultUISchema, VaultMethodSchema, FieldDescriptor, ApproveAction
} from "./flap/IVaultSchemasV1.sol";
import {Tournament} from "./Tournament.sol";

/// @title AssayFlapVault
/// @notice The Flap-facing vault: trading tax becomes BTCB prize money for verified optimisation work.
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
///      Why the prize is BTCB and not the native coin: a miner who wins a gas tournament is paid
///      for work, and being paid for work in the same asset whose price move you were not betting
///      on is the point. The tax arrives as BNB and is converted the moment it is put behind a
///      task, so a bounty is denominated in what will actually be paid out from the instant it is
///      announced. The miner therefore carries no market risk between winning and collecting, and
///      `collect` is a plain token transfer that cannot fail for a market reason.
///
///      Custody note: value that arrives here is assigned to a task the moment that task is
///      endowed, and can only ever leave to an address the tournament has already recorded a
///      score for. There is no owner, no upgrade path, and no sweep of endowed funds.
contract AssayFlapVault is VaultBaseV2 {
    using SafeERC20 for IERC20;

    /// @notice How far back `stats()` looks when counting still-open tasks.
    uint256 private constant STATS_SCAN = 64;

    /// @notice The asset every bounty is denominated in and paid out in.
    IERC20 public immutable reward;

    /// @notice The router the tax is converted through.
    IPancakeRouter02 public immutable router;

    /// @notice The router's wrapped native token — the first hop of the conversion path.
    address public immutable wrappedNative;

    /// @notice The tournament whose verified scores this vault pays against.
    Tournament public immutable tournament;

    /// @notice The tax token this vault belongs to, as told to us by the factory at creation.
    address public immutable taxToken;

    /// @notice Who may endow a task with accumulated BNB. Set at creation to the token's creator.
    address public immutable curator;

    /// @notice BTCB assigned to a task's bounty, by task id.
    mapping(uint256 taskId => uint256) public bounty;
    /// @notice BTCB already paid out of a task's bounty.
    mapping(uint256 taskId => uint256) public paid;
    /// @notice Whether a miner has taken their share of a task's bounty.
    mapping(uint256 taskId => mapping(address miner => bool)) public collected;

    /// @notice Sum of every task's unpaid bounty, in BTCB.
    uint256 public endowed;

    /// @notice BTCB this vault has paid out across every task.
    /// @dev Accumulated rather than summed on read: `stats()` is polled by a UI, and a view that
    ///      walks every task would get slower for exactly the vaults that are doing well.
    uint256 public totalPaid;

    /// @notice How many miner payouts have been made.
    uint256 public payouts;

    event RevenueReceived(address indexed from, uint256 amount);
    event Endowed(uint256 indexed taskId, uint256 bnbIn, uint256 rewardOut, uint256 unassignedLeft);
    event Sponsored(uint256 indexed taskId, address indexed from, uint256 amount);
    event BountyPaid(uint256 indexed taskId, address indexed miner, uint256 amount);

    error NotCurator();
    error NothingUnassigned();
    error NothingToSponsor();
    error UnsupportedRewardChain(uint256 chainId);
    error TaskNotSettled();
    error NoScore();
    error AlreadyCollected();

    /// @dev The reward token and the router are resolved from `block.chainid` and stored as
    ///      immutables, never accepted as arguments. A vault that lets its caller name the
    ///      protocol addresses it will send value through is a vault anyone can drain by naming
    ///      their own contract. Resolution happens once, at construction, so an unsupported
    ///      chain fails the launch outright instead of producing a vault that cannot pay.
    constructor(Tournament tournament_, address taxToken_, address curator_) {
        tournament = tournament_;
        taxToken = taxToken_;
        curator = curator_;

        uint256 chainId = block.chainid;
        address rewardToken;
        address routerAddr;
        if (chainId == 56) {
            rewardToken = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c; // BTCB Token
            routerAddr = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // PancakeSwap V2
        } else if (chainId == 97) {
            rewardToken = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8; // BTCB, BNB testnet
            routerAddr = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1; // PancakeSwap V2, testnet
        } else {
            revert UnsupportedRewardChain(chainId);
        }

        reward = IERC20(rewardToken);
        router = IPancakeRouter02(routerAddr);
        wrappedNative = IPancakeRouter02(routerAddr).WETH();
    }

    /// @notice Trading tax arrives here as native BNB.
    receive() external payable {
        emit RevenueReceived(msg.sender, msg.value);
    }

    // -------------------------------------------------------------------------------------
    // Revenue
    // -------------------------------------------------------------------------------------

    /// @notice Tax that has arrived as BNB and has not yet been converted behind a task.
    /// @dev Every native coin held here is unassigned by construction: the moment it is put
    ///      behind a task it stops being native and becomes BTCB.
    function unassigned() public view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Whether every open bounty is actually covered by tokens this vault holds.
    /// @dev The one invariant worth being able to check from outside without trusting a number
    ///      this contract reports about itself.
    function solvent() public view returns (bool) {
        return reward.balanceOf(address(this)) >= endowed;
    }

    /// @notice Converts accumulated BNB tax into BTCB and puts it behind a task's bounty.
    ///
    /// @dev Endowing is one-way. Once value is behind a task it can only leave to a miner the
    ///      tournament has scored, which is what stops a bounty being announced and then walked
    ///      back once somebody has done the work for it.
    ///
    ///      `minRewardOut` is the caller's floor on the conversion, not a suggestion — the swap
    ///      reverts below it. The bounty is booked at what actually arrived rather than at what
    ///      was quoted, because those are not the same number and only one of them is real.
    ///
    /// @param taskId       The task to put the money behind.
    /// @param bnbAmount    Native BNB to convert.
    /// @param minRewardOut Minimum BTCB the conversion must produce.
    function endow(uint256 taskId, uint256 bnbAmount, uint256 minRewardOut)
        external
        returns (uint256 rewardOut)
    {
        if (msg.sender != curator && msg.sender != _getGuardian()) revert NotCurator();
        uint256 free = unassigned();
        if (bnbAmount == 0 || bnbAmount > free) revert NothingUnassigned();

        address[] memory path = new address[](2);
        path[0] = wrappedNative;
        path[1] = address(reward);

        uint256[] memory amounts = router.swapExactETHForTokens{value: bnbAmount}(
            minRewardOut, path, address(this), block.timestamp
        );
        rewardOut = amounts[amounts.length - 1];

        bounty[taskId] += rewardOut;
        endowed += rewardOut;
        emit Endowed(taskId, bnbAmount, rewardOut, free - bnbAmount);
    }

    /// @notice Adds BTCB to a task's bounty directly, from anyone who wants to sponsor the work.
    /// @dev Deliberately unpermissioned. The money can only ever leave to a miner the tournament
    ///      has scored, so there is nothing to protect against here — and a bounty someone else
    ///      wants to make larger is a bounty that gets solved harder.
    function sponsor(uint256 taskId, uint256 amount) external {
        if (amount == 0) revert NothingToSponsor();
        reward.safeTransferFrom(msg.sender, address(this), amount);
        bounty[taskId] += amount;
        endowed += amount;
        emit Sponsored(taskId, msg.sender, amount);
    }

    /// @notice What one BNB of accumulated tax would currently convert to.
    /// @dev A quote, not a promise — it is what the UI shows beside the endow control so the
    ///      curator sets a slippage floor against a real number instead of a guess.
    function quote(uint256 bnbAmount) external view returns (uint256 rewardOut) {
        address[] memory path = new address[](2);
        path[0] = wrappedNative;
        path[1] = address(reward);
        uint256[] memory amounts = router.getAmountsOut(bnbAmount, path);
        return amounts[amounts.length - 1];
    }

    // -------------------------------------------------------------------------------------
    // Collecting
    // -------------------------------------------------------------------------------------

    /// @notice What `miner` can collect from a task's BTCB bounty right now.
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

    /// @notice Pays a scoring miner their share of a task's BTCB bounty.
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
        totalPaid += amount;
        ++payouts;

        reward.safeTransfer(msg.sender, amount);
        emit BountyPaid(taskId, msg.sender, amount);
    }

    // -------------------------------------------------------------------------------------
    // Headline numbers — the shape a generic vault UI can actually read
    // -------------------------------------------------------------------------------------

    /// @notice Everything a visitor should see at a glance, in one argument-free call.
    ///
    /// @dev Deliberately takes no arguments. Flap's generic vault renderer sorts a schema's
    ///      methods into exactly two buckets — argument-free reads, and writes — and silently
    ///      drops every read that needs a parameter. `getBounties` below is therefore invisible
    ///      there however useful it is on our own page, so the numbers that matter have to be
    ///      reachable from a call that asks for nothing.
    ///
    ///      `openTasks` scans the tail of the task list rather than all of it, so this stays
    ///      cheap to poll no matter how many tournaments have already settled.
    function stats()
        external
        view
        returns (
            uint256 tasks,
            uint256 openTasks,
            uint256 unassignedBnb,
            uint256 committedBtcb,
            uint256 paidBtcb,
            uint256 minersPaid
        )
    {
        tasks = tournament.taskCount();

        uint256 from = tasks > STATS_SCAN ? tasks - STATS_SCAN : 0;
        for (uint256 id = tasks; id > from; --id) {
            (, , uint64 revealEnd, , , , , , ) = tournament.tasks(id);
            if (block.timestamp < revealEnd) ++openTasks;
        }

        unassignedBnb = unassigned();
        committedBtcb = endowed;
        paidBtcb = totalPaid;
        minersPaid = payouts;
    }

    // -------------------------------------------------------------------------------------
    // Paginated views — the shape a card list is rendered from
    // -------------------------------------------------------------------------------------

    struct BountyCard {
        uint256 taskId;
        uint256 baselineGas;
        uint256 bountyBtcb;
        uint256 paidBtcb;
        uint256 entrants;
        uint256 phase;
        uint256 endsAt;
        uint256 yourScore;
        uint256 yourBtcb;
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
                bountyBtcb: bounty[id],
                paidBtcb: paid[id],
                entrants: tournament.scorers(id).length,
                phase: block.timestamp < commitEnd ? 0 : block.timestamp < revealEnd ? 1 : 2,
                endsAt: block.timestamp < commitEnd ? commitEnd : revealEnd,
                yourScore: score,
                yourBtcb: collectable(id, you)
            });
        }
    }

    // -------------------------------------------------------------------------------------
    // VaultBase
    // -------------------------------------------------------------------------------------

    /// @notice Live status line, polled by the UI as a banner.
    function description() public view override returns (string memory) {
        if (tournament.taskCount() == 0) return "No task has been posted yet.";
        if (unassigned() > 0) return "Trading tax has accumulated and is waiting to be converted to BTCB behind a task.";
        if (endowed > 0) return "A BTCB bounty is live. Beat the gas baseline to earn a share of it.";
        return "All bounties have been collected.";
    }

    // -------------------------------------------------------------------------------------
    // Self-describing UI
    // -------------------------------------------------------------------------------------

    /// @notice Describes this vault's interactive surface so a generic UI can render it.
    ///
    /// @dev Written for two readers at once, which is why the order matters.
    ///
    ///      Our own page renders the whole schema: `getBounties` returns an array and `collect`
    ///      sits beside it, which is the pairing that produces cards with a button on each row.
    ///
    ///      Flap's generic renderer is narrower — it shows argument-free reads and write methods,
    ///      and drops everything else — so `stats` leads, carrying the same headline numbers in a
    ///      form that survives there. Neither reader is given a schema shaped only for the other.
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "AssayVault";
        schema.description = unicode"Trading tax becomes BTCB prize money for verified gas-optimisation work. Miners submit EVM runtime bytecode; the chain deploys it, runs every test vector and reads the meter. / 交易税变成 BTCB 奖金,奖励可验证的优化工作。矿工提交 EVM 运行时字节码,链把它部署、跑完全部测试向量、读取计量表。";
        schema.methods = new VaultMethodSchema[](5);

        // 0 — the headline numbers, argument-free so every UI can read them.
        VaultMethodSchema memory m = schema.methods[0];
        m.name = "stats";
        m.description = unicode"Prize money at a glance / 奖金总览";
        m.inputs = new FieldDescriptor[](0);
        m.outputs = new FieldDescriptor[](6);
        m.outputs[0] = FieldDescriptor("tasks", "uint256", unicode"Tasks posted / 已发布任务", 0);
        m.outputs[1] = FieldDescriptor("openTasks", "uint256", unicode"Still open / 进行中", 0);
        m.outputs[2] = FieldDescriptor("unassignedBnb", "uint256", unicode"BNB tax awaiting conversion / 待兑换的 BNB 交易税", 18);
        m.outputs[3] = FieldDescriptor("committedBtcb", "uint256", unicode"BTCB behind live bounties / 已投入赏金的 BTCB", 18);
        m.outputs[4] = FieldDescriptor("paidBtcb", "uint256", unicode"BTCB paid to miners / 已付给矿工的 BTCB", 18);
        m.outputs[5] = FieldDescriptor("minersPaid", "uint256", unicode"Payouts made / 支付笔数", 0);
        m.approvals = new ApproveAction[](0);

        // 1 — the bounty cards.
        m = schema.methods[1];
        m.name = "getBounties";
        m.description = unicode"Every task and its BTCB bounty, newest first / 全部任务及其 BTCB 赏金,最新在前";
        m.inputs = new FieldDescriptor[](3);
        m.inputs[0] = FieldDescriptor("you", "address", unicode"Miner address / 矿工地址", 0);
        m.inputs[1] = FieldDescriptor("offset", "uint256", unicode"Skip / 跳过", 0);
        m.inputs[2] = FieldDescriptor("limit", "uint256", unicode"Page size / 每页数量", 0);
        m.outputs = new FieldDescriptor[](9);
        m.outputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.outputs[1] = FieldDescriptor("baselineGas", "uint256", unicode"Baseline to beat / 要跑赢的基准", 0);
        m.outputs[2] = FieldDescriptor("bountyBtcb", "uint256", unicode"BTCB bounty / BTCB 赏金", 18);
        m.outputs[3] = FieldDescriptor("paidBtcb", "uint256", unicode"Already paid / 已支付", 18);
        m.outputs[4] = FieldDescriptor("entrants", "uint256", unicode"Scoring miners / 有得分的矿工", 0);
        m.outputs[5] = FieldDescriptor("phase", "uint256", unicode"0 commit, 1 reveal, 2 settled / 0 承诺 1 揭示 2 已结算", 0);
        m.outputs[6] = FieldDescriptor("endsAt", "time", unicode"Phase ends / 本阶段结束", 0);
        m.outputs[7] = FieldDescriptor("yourScore", "uint256", unicode"Your score / 你的得分", 18);
        m.outputs[8] = FieldDescriptor("yourBtcb", "uint256", unicode"Collectable now / 现在可领", 18);
        m.approvals = new ApproveAction[](0);
        m.isOutputArray = true;

        // 2 — the button on every card.
        m = schema.methods[2];
        m.name = "collect";
        m.description = unicode"Collect your share of a task's BTCB bounty / 领取你在该任务 BTCB 赏金中的份额";
        m.inputs = new FieldDescriptor[](1);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;

        // 3 — converting revenue and putting it behind a task.
        m = schema.methods[3];
        m.name = "endow";
        m.description = unicode"Convert accumulated BNB tax to BTCB behind a task, one way (curator) / 把累计的 BNB 交易税兑成 BTCB 一次性投入某个任务(策展方)";
        m.inputs = new FieldDescriptor[](3);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.inputs[1] = FieldDescriptor("bnbAmount", "uint256", unicode"BNB to convert / 兑换的 BNB", 18);
        m.inputs[2] = FieldDescriptor("minRewardOut", "uint256", unicode"Minimum BTCB accepted / 最少接受的 BTCB", 18);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;

        // 4 — anyone may make a bounty larger.
        m = schema.methods[4];
        m.name = "sponsor";
        m.description = unicode"Add BTCB to a task's bounty. Open to anyone; it can only ever leave to a scoring miner. / 给某个任务的赏金追加 BTCB。任何人都可以,这笔钱只可能流向有得分的矿工。";
        m.inputs = new FieldDescriptor[](2);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.inputs[1] = FieldDescriptor("amount", "uint256", unicode"BTCB to add / 追加的 BTCB", 18);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](1);
        m.approvals[0] = ApproveAction("reward", "amount");
        m.isWriteMethod = true;
    }
}
