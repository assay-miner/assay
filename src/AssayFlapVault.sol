// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {IPancakeRouter02} from "./interfaces/IPancakeRouter02.sol";
import {PriceGuard} from "./PriceGuard.sol";
import {IFlapTriggerService, ITriggerReceiver} from "./flap/IFlapTriggerService.sol";
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
///      endowed, and `collect` — the path that pays it out — pays `msg.sender` and only when the
///      tournament has recorded a score for them. There is no owner and no upgrade path.
///
///      Two exceptions, stated here because the sentence above used to be written as absolute and
///      was not. `emergencyWithdrawToken` is `onlyGuardian` and moves the *entire* reward balance,
///      BTCB behind open bounties included, to an address the Guardian names, without reading or
///      reducing `endowed`; Flap Rule 009 requires that exact signature of every non-upgradeable
///      vault, so the gap is the price of the escape hatch and not an oversight. And
///      `withdrawUnconverted` sends tax that no conversion has bought yet to the fixed curator
///      address, which is not a scored miner either. `solvent()` is the reading that makes the
///      first gap visible from outside.
contract AssayFlapVault is VaultBaseV2, ReentrancyGuard, ITriggerReceiver {
    using SafeERC20 for IERC20;

    /// @notice How far back `stats()` looks when counting still-open tasks.
    uint256 private constant STATS_SCAN = 64;

    /// @notice The size used to read a spot price the pool has not yet been moved by.
    /// @dev Small enough that its own impact is negligible, large enough not to round to nothing.

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

    /// @notice Prices conversions and bounds their size. Fixed at construction: a caller-supplied
    ///         pricing contract would be a caller-supplied answer to "how much may I convert".
    PriceGuard public immutable priceGuard;

    /// @notice The router's wrapped native token — the first hop of the conversion path.
    address public immutable wrappedNative;

    /// @notice Flap's scheduler. The conversion is executed by its backend, not by the curator.
    IFlapTriggerService public immutable triggerService;

    /// @notice A conversion that has been scheduled and not yet executed.
    struct ScheduledEndow {
        uint128 bnbAmount;
        uint128 minRewardOut;
    }

    /// @notice Scheduled conversions, by the scheduler's request id.
    mapping(uint256 requestId => ScheduledEndow) public scheduled;

    /// @notice BNB already promised to a scheduled conversion.
    /// @dev `unassigned()` is the raw balance, which is what its name says and what the UI shows.
    ///      But a scheduled conversion escrows nothing, so without this a withdrawal could take
    ///      the BNB out from under an armed request: the callback would revert, its fee would be
    ///      spent for nothing, and tax on its way to a bounty would land as project revenue.
    uint256 public reserved;


    /// @notice BTCB that has been converted and belongs to no task yet.
    /// @dev Converting and funding used to be one call, which is precisely why the curator had
    ///      discretion: naming a task and naming an amount were the same action. They are two
    ///      mechanical steps now and neither takes a decision. This is what sits between them.
    uint256 public rewardPool;

    /// @notice When the last conversion was scheduled.
    uint256 public lastConversionAt;

    /// @notice One conversion per epoch.
    /// @dev The only constant left in the funding path, and the only one that is a choice rather
    ///      than a reading of state. Everything else is derived: a conversion takes whatever tax
    ///      has accrued, and a task takes whatever the pool holds.
    ///
    ///      Fixed sizes were the obvious design and they cannot do what is wanted here. A fixed
    ///      BNB input buys a variable amount of BTCB, so a fixed BTCB reward can never equal it
    ///      and the pool drifts — one of the two is always leaving something behind. Deriving both
    ///      ends makes an epoch's tax land in that epoch's task whatever the price did, which is
    ///      the property, and it removes two invented numbers rather than asking somebody to pick
    ///      them well.
    uint256 public constant CONVERSION_INTERVAL = 5 minutes;

    /// @notice How many scheduler fees a window must be worth before the vault pays to convert it.
    /// @dev The cadence funds itself out of the tax it converts, so it has to be worth paying for.
    ///      Ten leaves the fee under a tenth of what moves; below that the vault is buying its own
    ///      activity. A window under this simply waits and rolls into the next one.
    uint256 public constant FEE_COVER_MULTIPLE = 10;

    /// @notice The tournament whose verified scores this vault pays against.
    Tournament public immutable tournament;

    /// @notice The tax token this vault belongs to, as told to us by the factory at creation.
    address public immutable taxToken;

    /// @notice Where unconverted tax is returned to, and the only account besides the Guardian
    ///         that may cancel a scheduled conversion. Set at creation to the token's creator.
    /// @dev    It cannot endow. `endow` is the Guardian's alone — that is the point of it — and
    ///         this line used to claim otherwise.
    address public immutable curator;

    /// @notice BTCB assigned to a task's bounty, by task id.
    mapping(uint256 taskId => uint256) public bounty;
    /// @notice BTCB already paid out of a task's bounty.
    mapping(uint256 taskId => uint256) public paid;
    /// @notice Whether a miner has taken their share of a task's bounty.
    mapping(uint256 taskId => mapping(address miner => bool)) public collected;

    /// @dev Whether the pool has already been moved onto a task. Internal because nothing reads it
    ///      from outside and the getter costs code size the factory does not have; the event
    ///      `TaskFunded` already tells anyone watching that this happened.
    ///
    ///      This exists because `bounty[taskId] == 0` was the wrong question. `sponsor` is
    ///      deliberately open to anyone, so anyone could make a task's bounty non-zero with one wei
    ///      of BTCB and that task could then never be funded from the pool at all — a permanent
    ///      denial for the price of dust. What the one-shot rule is actually about is this pool
    ///      being moved once, so ask that directly and let sponsorship sit alongside it.
    mapping(uint256 taskId => bool) internal pooledInto;

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
    event ConversionScheduled(uint256 indexed requestId, uint256 bnbAmount, uint256 minRewardOut);
    event TaskFunded(uint256 indexed taskId, uint256 amount);
    event ConversionCancelled(uint256 indexed requestId, uint256 bnbAmount);
    event BountyReclaimed(uint256 indexed taskId, address indexed to, uint256 amount);
    event BountyRolledOver(uint256 indexed fromTaskId, uint256 amount);
    event Converted(uint256 bnbAmount, uint256 rewardOut, uint256 unassignedLeft);
    event UnconvertedWithdrawn(address indexed to, uint256 amount);
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
    constructor(Tournament tournament_, address taxToken_, address curator_, PriceGuard priceGuard_) {
        priceGuard = priceGuard_;
        tournament = tournament_;
        taxToken = taxToken_;
        curator = curator_;

        uint256 chainId = block.chainid;
        address rewardToken;
        address routerAddr;
        address triggerAddr;
        if (chainId == 56) {
            rewardToken = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c; // BTCB Token
            routerAddr = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // PancakeSwap V2
            triggerAddr = 0xcf4EE25035CF883895110f367F5BA8172416a7F9; // FlapTriggerService
        } else if (chainId == 97) {
            rewardToken = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8; // BTCB, BNB testnet
            routerAddr = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1; // PancakeSwap V2, testnet
            triggerAddr = 0x560E9830926C9e0EB98a59c6b9902383Fc0D9Eb2; // FlapTriggerService, testnet
        }
        require(rewardToken != address(0), unicode"Bad chain / 链不支持");

        reward = IERC20(rewardToken);
        router = IPancakeRouter02(routerAddr);
        wrappedNative = IPancakeRouter02(routerAddr).WETH();
        triggerService = IFlapTriggerService(triggerAddr);
    }

    /// @notice Trading tax arrives here as native BNB.
    receive() external payable {
        emit RevenueReceived(msg.sender, msg.value);
    }

    // -------------------------------------------------------------------------------------
    // Revenue
    // -------------------------------------------------------------------------------------


    /// @notice Tax that is neither converted nor already promised to a scheduled conversion.
    function freeTax() public view returns (uint256) {
        uint256 bal = address(this).balance;
        uint256 held = reserved;
        return bal > held ? bal - held : 0;
    }

    /// @notice Whether every open bounty is actually covered by tokens this vault holds.
    /// @dev The one invariant worth being able to check from outside without trusting a number
    ///      this contract reports about itself.
    function solvent() public view returns (bool) {
        return reward.balanceOf(address(this)) >= endowed;
    }

    /// @notice The Guardian's direct conversion, for when the scheduler cannot run.
    ///
    /// @dev Credits the pool like every other conversion, and names no task. Rule 009 wants the
    ///      Guardian able to act when the normal path is unavailable, and that is all this is —
    ///      it converts, and `fundTaskFromPool` moves it on afterwards like anybody else's.
    ///
    ///      Atomic rather than scheduled, so the Guardian both prices and executes it. That is a
    ///      real difference from `triggerConversion` and the reason it stays Guardian-only.
    function endow(uint256 bnbAmount, uint256 minRewardOut) external nonReentrant returns (uint256 rewardOut) {
        require(msg.sender == _getGuardian(), unicode"Only the guardian / 仅限守护者");
        require(
            bnbAmount > 0 && bnbAmount <= freeTax(),
            unicode"Exceeds unconverted tax / 超过未兑换的税"
        );
        _requireWithinImpact(bnbAmount);
        require(
            minRewardOut > 0
                && minRewardOut >= (quote(bnbAmount) * (10_000 - MAX_ENDOW_SLIPPAGE_BPS)) / 10_000,
            unicode"Slippage floor is too low / 滑点下限过低"
        );
        return _convertToPool(bnbAmount, minRewardOut);
    }

    /// @dev The swap and the booking, in one place because there are two ways in.
    ///
    ///      A rule written at one entry point and forgotten at the second is the defect this
    ///      codebase has produced most often. Both `endow` and the scheduler's callback land
    ///      here, so the amount booked is the amount that arrived, on both paths, by
    ///      construction rather than by two authors agreeing.
    /// @dev Credits the pool, not a task. What comes out is owed to whichever tasks the pool ends
    ///      up funding, so `endowed` rises here and falls only when a miner collects or an empty
    ///      window settles — the BTCB is spoken for from the moment it exists.
    function _convertToPool(uint256 bnbAmount, uint256 minRewardOut) private returns (uint256 rewardOut) {
        uint256 free = address(this).balance;
        address[] memory path = new address[](2);
        path[0] = wrappedNative;
        path[1] = address(reward);

        uint256[] memory amounts = router.swapExactETHForTokens{value: bnbAmount}(
            minRewardOut, path, address(this), block.timestamp
        );
        rewardOut = amounts[amounts.length - 1];

        rewardPool += rewardOut;
        endowed += rewardOut;
        emit Converted(bnbAmount, rewardOut, free - bnbAmount);
    }

    // -------------------------------------------------------------------------------------
    // Scheduled conversion — the curator's path
    // -------------------------------------------------------------------------------------

    /// @notice Schedules one conversion of tax into BTCB. Callable by anyone.
    ///
    /// @dev Takes no task and no amount. The size is a constant and the earliest next call is a
    ///      constant away from the last one, so the only thing a caller supplies is the fee and
    ///      the gas. Review asked for how much, which task and when to follow on-chain rules; this
    ///      is the first two, and the clock is the third.
    ///
    ///      It converts into a pool rather than into a task on purpose. Naming a task and naming an
    ///      amount were the same call, and that is where the discretion lived — splitting them
    ///      leaves neither half with a decision in it.
    ///
    ///      Execution still goes through Flap's Trigger Service at a moment the caller does not
    ///      choose, so scheduling remains a thing nobody can take a position on.
    function triggerConversion() external payable nonReentrant returns (uint256 requestId) {
        uint256 fee = triggerService.getFee();
        require(msg.value >= fee, unicode"Send the fee / 需附带费用");

        requestId = _arm(fee, msg.value);
        require(requestId != 0, unicode"Nothing to convert / 无可兑换");

        uint256 change = msg.value - fee;
        if (change > 0) {
            (bool ok,) = msg.sender.call{value: change}("");
            require(ok, unicode"Refund failed / 退款失败");
        }
    }

    /// @dev Sizes, prices and schedules one conversion, or returns zero if it cannot. One body so
    ///      the manual entry point and the self-arming one cannot drift — a rule written at one
    ///      call site and forgotten at the second is the defect this codebase has produced most.
    function _arm(uint256 fee, uint256 incoming) private returns (uint256 requestId) {
        if (address(this).balance < fee + incoming) return 0;

        // The caller's fee is sitting in this balance already, and it is not tax. Counting it
        // would convert somebody's fee into bounty and reserve more than the window produced.
        //
        // The subtraction is floored rather than written bare: once the vault has stalled, freeTax()
        // reads zero while a caller is still sending a fee, and `0 - incoming` panics with an
        // arithmetic underflow instead of returning the "Nothing to convert" this is supposed to
        // reach. That turned the one manual path out of a stall into a revert of its own.
        uint256 free = freeTax();
        uint256 amount = free > incoming ? free - incoming : 0;

        // When the vault arms ITSELF the fee leaves this same balance, and that balance is tax.
        // Reserving the un-netted amount over-reserves by exactly one fee, and the callback then
        // tries to swap more BNB than the vault holds — swapExactETHForTokens fails, trigger()
        // reverts with no try/catch around it, and the chain stops until somebody happens to send
        // at least a fee's worth of new tax. The manual path already had this netting via
        // `incoming`; the self-arming path is the second call site and never got it.
        if (incoming == 0) {
            // The fee leaves this balance, and this balance is tax.
            if (amount <= fee) return 0;
            amount -= fee;

            // Worth doing, not merely possible — and only here. A window that accrued barely more
            // than the fee costs almost as much to convert as it converts, and at one epoch every
            // five minutes that is 288 fees a day quietly draining a vault nobody is trading
            // against. That reasoning is entirely about spending tax on the scheduler, so it has no
            // claim on the manual path, where the caller supplies the fee themselves. The check sat
            // outside this block for two rounds while the comment beside it said it did not.
            //
            // Putting it back where the comment always said it belonged also restores what
            // `triggerConversion` is for: it is the restart when the self-arming chain has stopped,
            // and it was refusing to run in exactly the low-tax case where a stall is most likely.
            if (amount <= fee * FEE_COVER_MULTIPLE) return 0;
        }
        uint256 cap = maxConvertible();
        if (amount > cap) amount = cap;
        if (amount > type(uint128).max) return 0;
        if (priceGuard.impactBps(amount) > MAX_ENDOW_SLIPPAGE_BPS) return 0;

        uint256 floorOut = (quote(amount) * (10_000 - MAX_ENDOW_SLIPPAGE_BPS)) / 10_000;
        if (floorOut == 0 || floorOut > type(uint128).max) return 0;

        try triggerService.requestTrigger{value: fee}(uint64(block.timestamp + CONVERSION_INTERVAL))
        returns (uint256 next) {
            reserved += amount;
            scheduled[next] =
                ScheduledEndow({bnbAmount: uint128(amount), minRewardOut: uint128(floorOut)});
            emit ConversionScheduled(next, amount, floorOut);
            return next;
        } catch {
            return 0;
        }
    }

    /// @notice Pays one task its fixed reward out of the pool. Callable by anyone.
    /// @dev One-shot per task and the same amount for every task, so this is a transfer and not a
    ///      decision. A short pool pays what it has rather than reverting, so a task is never left
    ///      unfunded waiting for somebody to judge it worth funding.
    function fundTaskFromPool(uint256 taskId) external nonReentrant returns (uint256 amount) {
        _requireTask(taskId);
        require(!pooledInto[taskId], unicode"Already funded / 已注资");

        // The newest task only. Without this the caller chooses which live task the whole pool
        // lands on, so a miner who dominates some other open task can point this epoch's converted
        // tax at their own and take it in proportion to a score nobody was competing against. The
        // epoch's task is always the newest one, so naming it is not a decision either.
        require(taskId == tournament.taskCount(), unicode"Not the current task / 非当前任务");

        // The money has to be in place while people can still join. The first version of this
        // guard used revealEnd, which is a phase too late: commitment closes at commitEnd, so
        // across the whole reveal window the field is already frozen and funding still worked.
        // Anyone who had committed to a task nobody funded could wait for that window, move the
        // entire pool onto it, and take their share of a pot no one else could still enter for —
        // a sole committer taking all of it. Gating on commitEnd means the pot is decided before
        // the set of people dividing it is.
        (uint64 commitEnd,,, address poster) = tournament.taskGates(taskId);
        require(block.timestamp < commitEnd, unicode"Commitment closed / 承诺已截止");

        // And the task has to be one this project or the Guardian published. Requiring the NEWEST
        // task was not enough, which is the third time this function has been narrowed: posting is
        // deliberately open to strangers between epochs so a lost curator key cannot end the
        // tournament, and a stranger's task IS the newest one the moment they post it. So the
        // sequence was: wait for the gap, post a task only you are ready to solve, point the pool at
        // it because it is now the newest, and collect all of it as the sole scorer.
        //
        // Open posting exists so the tournament can continue without us. It was never a claim on
        // the treasury, and this is the line that says so. A stranger's task still runs, still
        // scores, and still pays out whatever its own poster escrowed — it just cannot be handed
        // the converted tax.
        require(
            poster == curator || poster == _getGuardian(),
            unicode"Task is not ours / 任务非本方发布"
        );

        // The whole pool. An epoch converts what it accrued and its task takes what that bought,
        // so nothing accumulates across epochs and no number here decides how much a task is worth.
        amount = rewardPool;
        require(amount > 0, unicode"Pool is empty / 池中无资金");

        rewardPool -= amount;
        pooledInto[taskId] = true;
        bounty[taskId] += amount;
        emit TaskFunded(taskId, amount);
    }

    /// @notice The scheduler's callback. Executes a conversion that was scheduled earlier.
    ///
    /// @dev Three things here are deliberate.
    ///
    ///      The entry is gated on the scheduler's own address, which is an immutable resolved
    ///      from the chain id, so nothing else can drive this.
    ///
    ///      The record is deleted before the swap. A revert undoes the deletion along with
    ///      everything else, so a failed conversion leaves the request intact and retryable
    ///      rather than consumed — which is the difference between a callback that can be
    ///      re-armed and one that is stuck forever.
    ///
    ///      And there is no `try`/`catch`. Swallowing a failed fulfilment would let the service
    ///      record the request as EXECUTED when nothing happened, and `retryTrigger` only works
    ///      on a request marked FAILED. Reverting is what keeps the retry path alive.
    function trigger(uint256 requestId) external override nonReentrant {
        require(msg.sender == address(triggerService), unicode"Only the scheduler / 仅限调度器");

        ScheduledEndow memory s = scheduled[requestId];
        require(s.bnbAmount > 0, unicode"No such request / 无此请求");
        delete scheduled[requestId];
        reserved -= s.bnbAmount;

        // Take the stricter of the floor priced when this was armed and one priced now. The stored
        // floor is minutes old by the time the service calls — the cadence is five minutes and the
        // service picks its own moment — so if BTCB moved up in between, that floor tolerates far
        // more than the 3% it was meant to and an MEV bot can take the difference.
        //
        // The fresh quote alone would be worse, not better: it reads the same pool the swap is
        // about to hit, so anyone able to move that pool in the same block would be setting our
        // floor for us. Neither number is trustworthy alone; the higher of the two is. A favourable
        // move tightens the floor, and an unfavourable or manufactured one cannot loosen it below
        // what we already committed to.
        uint256 fresh = (quote(s.bnbAmount) * (10_000 - MAX_ENDOW_SLIPPAGE_BPS)) / 10_000;
        uint256 floorNow = fresh > s.minRewardOut ? fresh : s.minRewardOut;

        _convertToPool(s.bnbAmount, floorNow);

        // Arm the next epoch from inside this one. The service has no recurrence of its own — its
        // documentation says a requester schedules the next trigger from the callback — so this is
        // where a cadence that needs nobody to remember it comes from.
        //
        // Deliberately best-effort. A failure here must not undo a conversion that has already
        // happened, and the reasons it can fail are ordinary: no tax accrued yet, the fee no
        // longer covered, the impact bound refusing a size the pool has moved under. When it does
        // fail the chain simply stops arming itself and `triggerConversion` restarts it, which is
        // visible as tax sitting unconverted rather than as anything silently wrong.
        _arm(triggerService.getFee(), 0);
    }

    /// @notice Drops a scheduled conversion. The BNB simply stays unconverted.
    /// @dev Present so a request that can never succeed — a floor the market has left behind, a
    ///      task that should not have been chosen — does not sit there waiting to fire at a time
    ///      nobody is watching. A later callback for a cancelled id finds nothing and reverts.
    function cancelConversion(uint256 requestId) external {
        require(
            msg.sender == curator || msg.sender == _getGuardian(),
            unicode"Only the curator / 仅限策展方"
        );
        ScheduledEndow memory s = scheduled[requestId];
        require(s.bnbAmount > 0, unicode"No such request / 无此请求");
        delete scheduled[requestId];
        reserved -= s.bnbAmount;
        emit ConversionCancelled(requestId, s.bnbAmount);
    }

    /// @notice What the scheduler charges to accept a request right now.
    function schedulerFee() external view returns (uint256) {
        return triggerService.getFee();
    }

    /// @notice Adds BTCB to a task's bounty directly, from anyone who wants to sponsor the work.
    /// @dev Deliberately unpermissioned. The money can only ever leave to a miner the tournament
    ///      has scored, so there is nothing to protect against here — and a bounty someone else
    ///      wants to make larger is a bounty that gets solved harder.
    function sponsor(uint256 taskId, uint256 amount) external nonReentrant {
        require(amount > 0, unicode"Amount is zero / 金额为零");
        _requireTask(taskId);

        // The bounty has to stop moving before anyone can collect against it. `collectable` reads
        // the live bounty as the pot, and `collect` pays each miner once, so a sponsorship landing
        // between two equal-scoring miners' collections pays the second one more than the first —
        // the same money, split by the order people happened to call in. This gate was written for
        // `fundTaskFromPool` and not for here, which is the same defect twice.
        (, uint64 revealEnd,,) = tournament.taskGates(taskId);
        require(block.timestamp < revealEnd, unicode"Settled / 已结算");
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

    /// @notice What the pool would pay per BNB if the trade were too small to move it.
    /// @dev Read from a probe rather than from reserves: it costs one view call, needs no pair

    /// @notice The largest amount that can be converted right now without moving the pool further
    ///         than the protocol tolerates.
    ///
    /// @dev Published rather than documented, because a documented chunk size is a number that
    ///      goes stale the moment liquidity moves — in either direction. This reads the pool as
    ///      it is. Binary search over a monotonic function: impact only grows with size, so


    /// @dev The check the floor was assumed to be and was not.
    ///
    ///      `MAX_ENDOW_SLIPPAGE_BPS` was compared against `quote(bnbAmount)`, and that quote
    ///      already prices the impact of that exact size — so the bound could never object to
    ///      it. Converting two thousand BNB in one call landed 47.6% under the untouched price
    ///      and passed, because the floor was measured against the number that already contained
    ///      the loss. Measuring against the price the pool would give an amount too small to
    ///      move it is what makes the bound mean what everyone read it as meaning.
    /// @notice What `bnbAmount` buys right now. Kept on the vault because the UI schema names it.
    function quote(uint256 bnbAmount) public view returns (uint256) {
        return priceGuard.quote(bnbAmount);
    }

    /// @notice The largest conversion that stays inside the impact bound.
    function maxConvertible() public view returns (uint256) {
        return priceGuard.maxConvertible();
    }

    function _requireWithinImpact(uint256 bnbAmount) internal view {
        uint256 impact = priceGuard.impactBps(bnbAmount);
        require(
            impact <= MAX_ENDOW_SLIPPAGE_BPS,
            unicode"Too big; see maxConvertible() / 金额过大,见 maxConvertible()"
        );
    }

    /// @notice What one BNB of accumulated tax would currently convert to.
    /// @dev A quote, not a promise — it is what the UI shows beside the endow control so the

    // -------------------------------------------------------------------------------------
    // Collecting
    // -------------------------------------------------------------------------------------

    /// @notice What `miner` can collect from a task's BTCB bounty right now.
    function collectable(uint256 taskId, address miner) public view returns (uint256) {
        if (collected[taskId][miner]) return 0;
        uint256 pot = bounty[taskId];
        // What is left, not what was booked. `reclaimBounty` settles a task by raising `paid` to
        // `bounty`, and a scorer who never collected still passes every other check here — so
        // reading `bounty` alone paid them out of whatever BTCB the vault held for other tasks.
        // `endowed` is a global sum and cannot see a hole in one task, so `solvent()` stayed true.
        uint256 left = pot - paid[taskId];
        if (left == 0) return 0;

        (, , , uint128 score, , ) = tournament.submissions(taskId, miner);
        if (score == 0) return 0;
        (,, uint256 totalScore,) = tournament.taskGates(taskId);
        if (totalScore == 0) return 0;
        uint256 share = (pot * score) / totalScore;
        return share > left ? left : share;
    }

    /// @notice Pays a scoring miner their share of a task's BTCB bounty.
    /// @dev Shares use the tournament's own recorded score, so the split here is the split there.
    function collect(uint256 taskId) external nonReentrant returns (uint256 amount) {
        (, uint64 revealEnd,,) = tournament.taskGates(taskId);
        require(block.timestamp >= revealEnd, unicode"Not settled yet / 尚未结算");
        require(!collected[taskId][msg.sender], unicode"Already collected / 已经领取过了");

        amount = collectable(taskId, msg.sender);
        require(amount > 0, unicode"Nothing to collect / 无可领取");

        collected[taskId][msg.sender] = true;
        paid[taskId] += amount;
        endowed -= amount;
        totalPaid += amount;
        ++payouts;

        reward.safeTransfer(msg.sender, amount);
        emit BountyPaid(taskId, msg.sender, amount);
    }

    /// @notice Takes back tax that was never placed behind a task.
    ///
    /// @dev The other half of not being stuck, and the half that bites first. Tax accrues here
    ///      continuously; a task is posted for a window. Tax that arrives while no task is open,
    ///      or that is simply more than the curator chose to put up, was reachable by nothing —
    ///      not `collect`, which needs a score, and not any curator path, because every one of
    ///      them only converted *into* a task. It sat here until Flap's Guardian moved it.
    ///
    ///      Nothing is owed out of it. A miner's claim attaches when tax is converted and booked
    ///      behind a task, and that step is still one-way: `endowed` is untouchable here, and
    ///      this can only ever move native value, which by construction is the unconverted part.
    ///      What it changes is who bears an empty window — the project, rather than nobody.
    function withdrawUnconverted(uint256 amount) external nonReentrant returns (uint256 sent) {
        // Anyone may call this, and it can only ever pay `curator`. Both halves are the point.
        //
        // The destination was never the objection — an empty window's tax belongs to the project
        // by design, and that address is fixed at construction so no caller chooses it. Choosing
        // *when* to take it was the objection, and rightly: the old gate let the curator pull tax
        // out from under a task miners were still working on. So the condition is the epoch's, not
        // a permission: while the most recent task is still open this reverts for everybody,
        // including the curator and the Guardian, and once it has settled it works for anybody.
        //
        // With no task ever posted there is nothing to wait for, which is exactly the case the
        // rule is about: a window in which nothing was published belongs to the project.
        require(block.timestamp >= tournament.latestRevealEnd(), unicode"Epoch open / 本期未结束");
        uint256 free = freeTax();
        sent = amount == 0 || amount > free ? free : amount;
        require(sent > 0, unicode"No unconverted tax / 无未兑换的税");

        (bool ok,) = curator.call{value: sent}("");
        require(ok, unicode"Transfer failed / 转账失败");
        emit UnconvertedWithdrawn(curator, sent);
    }

    /// @notice Returns a finished task's unclaimed remainder to the pool. Callable by anyone.
    ///
    /// @dev This paid the curator once, then paid the curator only when nobody had scored, and now
    ///      pays nobody. Review pushed twice, and the second push was right: a bounty nobody
    ///      claimed is money the tournament raised, and there is no reading of "the project's
    ///      share" that survives the project no longer choosing which task got funded or how much.
    ///      It goes back into `rewardPool` and funds a later task.
    ///
    ///      Which also empties the function of decisions, so it needs no permission. There is no
    ///      destination to protect: the BTCB does not leave the vault, `endowed` does not move, and
    ///      a caller pays gas to settle a task that has already ended.
    ///
    ///      The conditions are still the tournament's own. Reveal must have closed, and if anybody
    ///      scored, the claim window must have passed too — so this can never race a miner who is
    ///      on their way to collect.
    function reclaimBounty(uint256 taskId) external nonReentrant returns (uint256 amount) {
        _requireTask(taskId);

        (, uint64 revealEnd, uint256 totalScore,) = tournament.taskGates(taskId);
        require(block.timestamp >= revealEnd, unicode"Not settled yet / 尚未结算");
        require(
            totalScore == 0 || block.timestamp >= uint256(revealEnd) + tournament.CLAIM_WINDOW(),
            unicode"Miners can still collect / 矿工仍可领取"
        );

        amount = bounty[taskId] - paid[taskId];
        require(amount > 0, unicode"Nothing left / 已无剩余");

        // Booked as paid so the ledger cannot hand the same BTCB out twice. `endowed` does not
        // move, because the BTCB does not — it only stops belonging to this task.
        paid[taskId] += amount;
        rewardPool += amount;
        emit BountyRolledOver(taskId, amount);
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
            require(ok, unicode"Transfer failed / 转账失败");
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
            (, uint64 revealEnd,,) = tournament.taskGates(id);
            if (block.timestamp < revealEnd) ++openTasks;
        }

        unassignedBnb = address(this).balance;
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
        if (tournament.taskCount() == 0) return unicode"No task yet / 尚未发布任务";
        if (address(this).balance > 0) {
            return unicode"Tax unconverted / 税款待兑换";
        }
        if (endowed > 0) {
            return unicode"Bounty live / 赏金进行中";
        }
        return unicode"Bounties collected / 赏金已领取";
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
        schema.description = unicode"Tax becomes BTCB prizes / 税变 BTCB 奖金";
        schema.methods = new VaultMethodSchema[](12);

        // 0 — the headline numbers, argument-free so every UI can read them.
        VaultMethodSchema memory m = schema.methods[0];
        m.name = "stats";
        m.description = unicode"Prize money / 奖金总览";
        m.inputs = new FieldDescriptor[](0);
        m.outputs = new FieldDescriptor[](6);
        m.outputs[0] = FieldDescriptor("tasks", "uint256", unicode"Tasks posted / 已发布任务", 0);
        m.outputs[1] = FieldDescriptor("openTasks", "uint256", unicode"Still open / 进行中", 0);
        m.outputs[2] = FieldDescriptor("unassignedBnb", "uint256", unicode"BNB awaiting conversion / 待兑换的 BNB", 18);
        m.outputs[3] = FieldDescriptor("committedBtcb", "uint256", unicode"BTCB in bounties / 赏金中的 BTCB", 18);
        m.outputs[4] = FieldDescriptor("paidBtcb", "uint256", unicode"BTCB paid to miners / 已付矿工的 BTCB", 18);
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
        m.description = unicode"Holdings cover bounties / 覆盖赏金";
        m.inputs = new FieldDescriptor[](0);
        m.outputs = new FieldDescriptor[](1);
        m.outputs[0] = FieldDescriptor("covered", "bool", unicode"Covered / 已覆盖", 0);
        m.approvals = new ApproveAction[](0);

        // 2 — the bounty cards.
        m = schema.methods[2];
        m.name = "getBounties";
        m.description = unicode"Tasks / 任务与赏金";
        m.inputs = new FieldDescriptor[](3);
        m.inputs[0] = FieldDescriptor("you", "address", unicode"Miner / 矿工", 0);
        m.inputs[1] = FieldDescriptor("offset", "uint256", unicode"Skip / 跳过", 0);
        m.inputs[2] = FieldDescriptor("limit", "uint256", unicode"Page size / 每页", 0);
        m.outputs = new FieldDescriptor[](9);
        m.outputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.outputs[1] = FieldDescriptor("baselineGas", "uint256", unicode"Baseline to beat / 要跑赢的基准", 0);
        m.outputs[2] = FieldDescriptor("bountyBtcb", "uint256", unicode"Bounty / 赏金", 18);
        m.outputs[3] = FieldDescriptor("paidBtcb", "uint256", unicode"Paid / 已付", 18);
        m.outputs[4] = FieldDescriptor("entrants", "uint256", unicode"Scorers / 得分者", 0);
        m.outputs[5] = FieldDescriptor("phase", "uint256", unicode"0/1/2 commit reveal settled / 承诺 揭示 结算", 0);
        m.outputs[6] = FieldDescriptor("endsAt", "time", unicode"Phase ends / 本阶段结束", 0);
        m.outputs[7] = FieldDescriptor("yourScore", "uint256", unicode"Your score / 你的得分", 18);
        m.outputs[8] = FieldDescriptor("yourBtcb", "uint256", unicode"Collectable now / 现在可领", 18);
        m.approvals = new ApproveAction[](0);
        m.isOutputArray = true;

        // 3 — the button on every card.
        m = schema.methods[3];
        m.name = "collect";
        m.description = unicode"Collect / 领取份额";
        m.inputs = new FieldDescriptor[](1);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;

        // 4 — converting revenue and putting it behind a task.
        m = schema.methods[4];
        m.name = "endow";
        m.description = unicode"Add to the pool / 向池中注资";
        m.inputs = new FieldDescriptor[](2);
        m.inputs[0] = FieldDescriptor("bnbAmount", "uint256", unicode"BNB to convert / 兑换的 BNB", 18);
        m.inputs[1] = FieldDescriptor("minRewardOut", "uint256", unicode"Min BTCB out / 最少换得", 18);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;

        // 5 — anyone may make a bounty larger.
        m = schema.methods[5];
        m.name = "sponsor";
        m.description = unicode"Add BTCB / 追加 BTCB";
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
        m.description = unicode"Collectable / 能领多少";
        m.inputs = new FieldDescriptor[](2);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.inputs[1] = FieldDescriptor("miner", "address", unicode"Miner / 矿工", 0);
        m.outputs = new FieldDescriptor[](1);
        m.outputs[0] = FieldDescriptor("amount", "uint256", unicode"Amount / 数量", 18);
        m.approvals = new ApproveAction[](0);

        // 7 — funding the open task. No inputs: the vault derives all of them.
        m = schema.methods[7];
        m.name = "triggerConversion";
        m.description = unicode"Convert tax / 兑换本期税";
        m.inputs = new FieldDescriptor[](0);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;

        // 8 — an empty window's tax goes back to the project rather than nowhere.
        m = schema.methods[8];
        m.name = "withdrawUnconverted";
        m.description = unicode"Take back tax / 取回未投入税";
        m.inputs = new FieldDescriptor[](1);
        m.inputs[0] = FieldDescriptor("amount", "uint256", unicode"BNB, 0 for all / BNB,0 表示全部", 18);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;

        // 9 — a bounty nobody won, on the tournament's own terms.
        m = schema.methods[9];
        m.name = "reclaimBounty";
        m.description = unicode"Return bounty / 收回无人赢的赏金";
        m.inputs = new FieldDescriptor[](1);
        m.inputs[0] = FieldDescriptor("taskId", "uint256", unicode"Task / 任务", 0);
        m.outputs = new FieldDescriptor[](0);
        m.approvals = new ApproveAction[](0);
        m.isWriteMethod = true;

        // 10 — how much the pool can take right now, so nobody has to guess.
        m = schema.methods[10];
        m.name = "maxConvertible";
        m.description = unicode"Max convertible / 最多能兑换";
        m.inputs = new FieldDescriptor[](0);
        m.outputs = new FieldDescriptor[](1);
        m.outputs[0] = FieldDescriptor("bnbAmount", "uint256", unicode"Amount / 数量", 18);
        m.approvals = new ApproveAction[](0);

        // 11 — the conversion the curator is about to accept.
        m = schema.methods[11];
        m.name = "quote";
        m.description = unicode"Converts to / 能换到多少";
        m.inputs = new FieldDescriptor[](1);
        m.inputs[0] = FieldDescriptor("bnbAmount", "uint256", unicode"Amount / 数量", 18);
        m.outputs = new FieldDescriptor[](1);
        m.outputs[0] = FieldDescriptor("rewardOut", "uint256", unicode"Amount / 数量", 18);
        m.approvals = new ApproveAction[](0);
    }
}
