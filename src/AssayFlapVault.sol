// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

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
contract AssayFlapVault is VaultBaseV2, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice How far back `stats()` looks when counting still-open tasks.
    uint256 private constant STATS_SCAN = 64;

    /// @notice The worst conversion `endow` will accept, measured against the pool's spot price.
    /// @dev A floor the caller picks freely is a floor the caller can set to zero, and the caller
    ///      here is privileged. With no lower bound the curator could sandwich the vault's own
    ///      conversion and keep the difference — the money is the token's tax, so that is value
    ///      taken from the bounty rather than from them. This bounds it to 3%.
    uint256 private constant MAX_ENDOW_SLIPPAGE_BPS = 300;

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
    event EmergencyWithdrawNative(address indexed to, uint256 amount);
    event EmergencyWithdrawToken(address indexed token, address indexed to, uint256 amount);

    /// @dev Every revert here is a `require` with a literal bilingual string rather than a custom
    ///      error. Flap's renderer has no ABI to decode a selector against, so a custom error
    ///      reaches the user as four unreadable bytes; a literal string is shown as written, and
    ///      the protocol asks for both languages in the same one because there is no translation
    ///      layer between this contract and the screen.

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
            revert(unicode"Reward asset is not deployed on this chain / 本链没有部署奖励资产");
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
        nonReentrant
        returns (uint256 rewardOut)
    {
        require(
            msg.sender == curator || msg.sender == _getGuardian(),
            unicode"Only the curator may convert tax / 只有策展方可以兑换交易税"
        );
        _requireTask(taskId);
        uint256 free = unassigned();
        require(
            bnbAmount > 0 && bnbAmount <= free,
            unicode"Amount exceeds the unconverted tax / 金额超过了未兑换的交易税"
        );

        // The caller still chooses the floor, but not freely: it may not sit further below the
        // pool's own price than the protocol allows. This does not make the conversion
        // unsandwichable — an attacker who moves the pool first also moves the reading this is
        // measured against — but it removes the case where a privileged caller simply declares
        // that any price is acceptable, which is the one an insider can arrange at will.
        uint256 spot = quote(bnbAmount);
        require(
            minRewardOut > 0
                && minRewardOut >= (spot * (10_000 - MAX_ENDOW_SLIPPAGE_BPS)) / 10_000,
            unicode"Slippage floor is too low / 滑点下限过低"
        );

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
    function sponsor(uint256 taskId, uint256 amount) external nonReentrant {
        require(amount > 0, unicode"Amount must be greater than zero / 金额必须大于零");
        _requireTask(taskId);
        reward.safeTransferFrom(msg.sender, address(this), amount);
        bounty[taskId] += amount;
        endowed += amount;
        emit Sponsored(taskId, msg.sender, amount);
    }

    /// @dev Money behind a task that does not exist is money nobody can ever take out: no score
    ///      is ever recorded against it, so `collectable` stays zero and `collect` reverts for
    ///      good. There is no owner and no sweep here by design, which makes a mistyped task id
    ///      a permanent loss rather than an inconvenience. Task ids start at one.
    function _requireTask(uint256 taskId) internal view {
        require(
            taskId > 0 && taskId <= tournament.taskCount(),
            unicode"No such task / 该任务不存在"
        );
    }

    /// @notice What one BNB of accumulated tax would currently convert to.
    /// @dev A quote, not a promise — it is what the UI shows beside the endow control so the
    ///      curator sets a slippage floor against a real number instead of a guess.
    function quote(uint256 bnbAmount) public view returns (uint256 rewardOut) {
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
    function collect(uint256 taskId) external nonReentrant returns (uint256 amount) {
        (, , uint64 revealEnd, , , , , , ) = tournament.tasks(taskId);
        require(block.timestamp >= revealEnd, unicode"Task has not settled yet / 该任务尚未结算");
        require(!collected[taskId][msg.sender], unicode"Already collected / 已经领取过了");

        amount = collectable(taskId, msg.sender);
        require(amount > 0, unicode"Nothing to collect on this task / 该任务没有可领取的份额");

        collected[taskId][msg.sender] = true;
        paid[taskId] += amount;
        endowed -= amount;
        totalPaid += amount;
        ++payouts;

        reward.safeTransfer(msg.sender, amount);
        emit BountyPaid(taskId, msg.sender, amount);
    }

    // -------------------------------------------------------------------------------------
    // Emergency controls — Flap Rule 009
    // -------------------------------------------------------------------------------------

    /// @dev Reserved to the Guardian. Deliberately not `curator or Guardian`: the protocol
    ///      requires that the party who runs this vault day to day cannot reach the escape hatch.
    modifier onlyGuardian() {
        require(msg.sender == _getGuardian(), unicode"Only the guardian / 仅限守护者");
        _;
    }

    /// @notice Drains the vault's native balance to a safe address.
    ///
    /// @dev Present because Flap requires it of every non-upgradeable vault, and it is worth
    ///      being plain about what it means rather than filing it under "emergency": the
    ///      Guardian is Flap's address, not ours, and this reaches the BTCB behind open
    ///      bounties as well as the unconverted tax. Everything else in this contract is
    ///      arranged so that money can only move to a miner the tournament scored; this is the
    ///      one path that is not, and the protocol's trust anchor is Flap either way — their
    ///      portal can already redirect where this token's tax is sent.
    function emergencyWithdrawNative(address to) external onlyGuardian nonReentrant {
        require(to != address(0), unicode"Zero address / 地址为零");
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = to.call{value: bal}("");
            require(ok, unicode"Native transfer failed / 原生代币转账失败");
            emit EmergencyWithdrawNative(to, bal);
        }
    }

    /// @notice Recovers any ERC-20 stuck in the vault, including the reward token.
    function emergencyWithdrawToken(address token, address to) external onlyGuardian nonReentrant {
        require(token != address(0) && to != address(0), unicode"Zero address / 地址为零");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
            emit EmergencyWithdrawToken(token, to, bal);
        }
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
        schema.methods = new VaultMethodSchema[](8);

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

        // 1 — the invariant, argument-free so it is always on screen.
        //
        // Listed deliberately rather than left as an internal check. The Guardian's emergency
        // withdrawal drains tokens without touching `endowed`, which is what the protocol
        // specifies — so after one, this contract's own figures would claim money is behind
        // tasks that is not there. This is the reading that says so, and it costs nothing to
        // put it where anyone can see it.
        m = schema.methods[1];
        m.name = "solvent";
        m.description = unicode"Whether the tokens held actually cover every open bounty / 持有的代币是否真的覆盖了全部未结赏金";
        m.inputs = new FieldDescriptor[](0);
        m.outputs = new FieldDescriptor[](1);
        m.outputs[0] = FieldDescriptor("covered", "bool", unicode"Covered / 已覆盖", 0);
        m.approvals = new ApproveAction[](0);

        // 2 — the bounty cards.
        m = schema.methods[2];
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

        // 3 — the button on every card.
        m = schema.methods[3];
        m.name = "collect";
        m.description = unicode"Collect your share of a task's BTCB bounty / 领取你在该任务 BTCB 赏金中的份额";
        m.inputs = new FieldDescriptor[](1);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;

        // 4 — converting revenue and putting it behind a task.
        m = schema.methods[4];
        m.name = "endow";
        m.description = unicode"Convert accumulated BNB tax to BTCB behind a task, one way (curator) / 把累计的 BNB 交易税兑成 BTCB 一次性投入某个任务(策展方)";
        m.inputs = new FieldDescriptor[](3);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.inputs[1] = FieldDescriptor("bnbAmount", "uint256", unicode"BNB to convert / 兑换的 BNB", 18);
        m.inputs[2] = FieldDescriptor("minRewardOut", "uint256", unicode"Minimum BTCB accepted / 最少接受的 BTCB", 18);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;

        // 5 — anyone may make a bounty larger.
        m = schema.methods[5];
        m.name = "sponsor";
        m.description = unicode"Add BTCB to a task's bounty. Open to anyone; it can only ever leave to a scoring miner. / 给某个任务的赏金追加 BTCB。任何人都可以,这笔钱只可能流向有得分的矿工。";
        m.inputs = new FieldDescriptor[](2);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.inputs[1] = FieldDescriptor("amount", "uint256", unicode"BTCB to add / 追加的 BTCB", 18);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](1);
        m.approvals[0] = ApproveAction("reward", "amount");
        m.isWriteMethod = true;

        // 6 — what one miner is owed on one task.
        m = schema.methods[6];
        m.name = "collectable";
        m.description = unicode"What an address can collect from a task right now / 某个地址现在能从该任务领取多少";
        m.inputs = new FieldDescriptor[](2);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.inputs[1] = FieldDescriptor("miner", "address", unicode"Miner address / 矿工地址", 0);
        m.outputs = new FieldDescriptor[](1);
        m.outputs[0] = FieldDescriptor("amount", "uint256", unicode"BTCB / BTCB", 18);
        m.approvals = new ApproveAction[](0);

        // 7 — the conversion the curator is about to accept.
        m = schema.methods[7];
        m.name = "quote";
        m.description = unicode"What that much BNB converts to at the pool's current price / 这么多 BNB 按当前池价能换到多少";
        m.inputs = new FieldDescriptor[](1);
        m.inputs[0] = FieldDescriptor("bnbAmount", "uint256", unicode"BNB / BNB", 18);
        m.outputs = new FieldDescriptor[](1);
        m.outputs[0] = FieldDescriptor("rewardOut", "uint256", unicode"BTCB / BTCB", 18);
        m.approvals = new ApproveAction[](0);
    }
}
