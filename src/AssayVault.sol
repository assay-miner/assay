// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @title AssayVault
/// @notice The single place any ASSAY value is held.
///
/// @dev Custody is deliberately separated from logic. The tournament decides *who* has earned
///      what; it never holds the money while deciding. That split buys three properties that a
///      contract holding its own balance cannot have:
///
///      1. **Namespaced accounts.** An account id is derived by this contract from `msg.sender`,
///         never supplied by the caller. A controller therefore cannot name — let alone move —
///         an account belonging to another controller. The roster cannot touch a prize pot and
///         the tournament cannot touch a miner's stake, and that is enforced by the id
///         derivation rather than by a rule someone has to remember.
///
///      2. **Every unit is attributed.** `totalAccounted` is the sum of every account balance,
///         and a payout can only ever draw on the named account. Value that is not in an account
///         is not payable by anyone, so a stray transfer into this contract cannot be raked into
///         a payout and made to look like a profit.
///
///      3. **No operator reach.** There is no owner, no pause, no upgrade path, no rescue of
///         accounted funds, and no admin key. The controllers are named once at deploy and then
///         frozen. The only thing anyone can move out of here is a balance the ledger already
///         says belongs to the address being paid.
///
///      The one deliberate exception is the salvage path, which can move *only* value the ledger
///      has never attributed to anyone, and only ever to an address fixed at deployment. It is
///      bounded by arithmetic, not by trust, and it exists so a fat-fingered transfer is
///      recoverable instead of stranded here forever.
///
///      The ledger denominates exactly one thing: `asset`. That is what makes the salvage path
///      total rather than partial. For `asset` the sweepable amount is the surplus over
///      `totalAccounted`; for every *other* token, and for native value, the sweepable amount is
///      the entire balance, because no unit of any of them has ever been, or can ever be,
///      credited to an account. Both branches are the same rule — "move what nobody owns" — and
///      neither branch has a parameter an attacker can steer: the destination is immutable, the
///      amount is derived, and the caller keeps nothing but the gas bill.
///
///      Two structural guards keep the foreign-token branch honest. First, a token that is
///      merely an *alias* for `asset` (a second entry point onto the same balance, the shape
///      that has drained real vaults) is caught after the fact: any sweep that lowers this
///      contract's `asset` balance reverts, so the alias trick cannot reach accounted funds even
///      though the address comparison misses it. Second, no controller may ever settle a
///      deposit by pushing tokens here and crediting them in a later call: a pre-transferred
///      balance is by definition unaccounted, and anyone may sweep it in between. Every inflow
///      must be a pull inside `deposit`, which is what the four value paths already do.
///
///      This contract has no `receive` and no `payable` function, so native value cannot be sent
///      here by accident; `sweepNative` exists for the two ways it can arrive anyway — a
///      `selfdestruct` beneficiary and a block-reward address — which no contract can refuse.
contract AssayVault {
    using SafeERC20 for IERC20;

    /// @notice The only asset this vault custodies.
    IERC20 public immutable asset;

    /// @notice Where an accidental transfer into this contract can be swept. Fixed at deploy.
    address public immutable salvage;

    address public immutable deployer;

    /// @notice Contracts permitted to open accounts and move value inside their own namespace.
    mapping(address controller => bool) public isController;
    /// @notice Once true, the controller set can never change again.
    bool public controllersFrozen;

    /// @notice Ledger. Keys are opaque ids derived from the controller that owns them.
    mapping(bytes32 account => uint256) public balanceOf;

    /// @notice Sum of every account balance. The real token balance may never fall below it.
    uint256 public totalAccounted;

    event ControllerAdded(address indexed controller);
    event ControllersFrozen();
    event Deposited(address indexed controller, bytes32 indexed account, address indexed from, uint256 amount);
    event Moved(address indexed controller, bytes32 indexed from, bytes32 indexed to, uint256 amount);
    event Paid(address indexed controller, bytes32 indexed account, address indexed to, uint256 amount);
    event SweptUnaccounted(address indexed to, uint256 amount);
    event SweptToken(address indexed token, address indexed to, uint256 amount);
    event SweptNative(address indexed to, uint256 amount);


    constructor(IERC20 asset_, address salvage_) {
        require(address(asset_) != address(0) && salvage_ != address(0), unicode"Zero address / 零地址");
        asset = asset_;
        salvage = salvage_;
        deployer = msg.sender;
    }

    /// @dev Two conditions, not one. The controller check is the obvious half. The freeze check
    ///      is the half that closes a window in the *deployment*, not in the contract: a forge
    ///      broadcast is N separate transactions, so `addController` and `freeze()` land in
    ///      different blocks with a gap in between. In that gap a compromised deployer key could
    ///      name a hostile controller, and a hostile controller can call `deposit(from: victim)`
    ///      against any standing allowance this vault has been granted, then pay itself out.
    ///      Refusing to move value until the controller set is sealed makes that gap unusable
    ///      instead of merely unused, in this deployment and in every future one.
    modifier onlyController() {
        require(controllersFrozen, unicode"Controllers not frozen / 控制者尚未冻结");
        require(isController[msg.sender], unicode"Not a controller / 非控制者");
        _;
    }

    /// @dev Transient (EIP-1153) lock, held only for the duration of one sweep. It is not a
    ///      pause and nobody can set it: it exists so that a hostile token — the one call in
    ///      this contract that hands control to an address the caller chose — cannot re-enter
    ///      the salvage path mid-flight. Transient rather than stored, so the contract owns no
    ///      mutable state that could survive a transaction in the locked position.
    // keccak256("assay.vault.sweep.lock") - 1
    bytes32 private constant _SWEEP_LOCK = 0x464c465f2fb43cfbc3544d30251a2ea8b8f49c724893b25068323ab5f9b58083;

    modifier nonReentrantSweep() {
        uint256 locked;
        assembly ("memory-safe") {
            locked := tload(_SWEEP_LOCK)
        }
        require(locked == 0, unicode"Sweep reentered / 清扫重入");
        assembly ("memory-safe") {
            tstore(_SWEEP_LOCK, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(_SWEEP_LOCK, 0)
        }
    }

    // -------------------------------------------------------------------------------------
    // Wiring — done once, at deploy, then sealed
    // -------------------------------------------------------------------------------------

    /// @notice Names a contract allowed to hold accounts here.
    /// @dev Only callable before freezing, and freezing is irreversible. After `freeze()` the
    ///      controller set is part of the deployment rather than a setting.
    function addController(address controller) external {
        require(msg.sender == deployer, unicode"Not the deployer / 非部署者");
        require(!controllersFrozen, unicode"Controllers are frozen / 控制者已冻结");
        require(controller != address(0), unicode"Zero address / 零地址");
        isController[controller] = true;
        emit ControllerAdded(controller);
    }

    /// @notice Seals the controller set forever.
    function freeze() external {
        require(msg.sender == deployer, unicode"Not the deployer / 非部署者");
        require(!controllersFrozen, unicode"Controllers are frozen / 控制者已冻结");
        controllersFrozen = true;
        emit ControllersFrozen();
    }

    // -------------------------------------------------------------------------------------
    // Account ids
    // -------------------------------------------------------------------------------------

    /// @notice The id a given controller's account resolves to.
    /// @dev Public so anybody can independently compute and audit a balance. The controller is
    ///      part of the preimage, which is what makes namespaces non-forgeable: no argument a
    ///      caller can pass will produce another controller's id.
    function accountId(address controller, bytes32 kind, bytes32 key) public pure returns (bytes32) {
        return keccak256(abi.encode(controller, kind, key));
    }

    /// @notice The caller's own account id for `(kind, key)`.
    function ownAccount(bytes32 kind, bytes32 key) public view returns (bytes32) {
        return accountId(msg.sender, kind, key);
    }

    // -------------------------------------------------------------------------------------
    // Value movement — all four paths, and there are only four
    // -------------------------------------------------------------------------------------

    /// @notice Pulls `amount` from `from` into the caller's `(kind, key)` account.
    /// @dev The vault pulls directly, so the tokens never sit in the controller even for one
    ///      call. `from` must have approved this vault.
    function deposit(bytes32 kind, bytes32 key, address from, uint256 amount)
        external
        onlyController
        returns (bytes32 account)
    {
        account = ownAccount(kind, key);
        balanceOf[account] += amount;
        totalAccounted += amount;
        asset.safeTransferFrom(from, address(this), amount);
        emit Deposited(msg.sender, account, from, amount);
    }

    /// @notice Moves value between two accounts the caller owns. Nothing leaves the vault.
    function move(bytes32 fromKind, bytes32 fromKey, bytes32 toKind, bytes32 toKey, uint256 amount)
        external
        onlyController
    {
        bytes32 from = ownAccount(fromKind, fromKey);
        bytes32 to = ownAccount(toKind, toKey);
        uint256 have = balanceOf[from];
        require(have >= amount, unicode"Account is short / 账户余额不足");
        unchecked {
            balanceOf[from] = have - amount;
        }
        balanceOf[to] += amount;
        emit Moved(msg.sender, from, to, amount);
    }

    /// @notice Pays `amount` out of the caller's `(kind, key)` account to `to`.
    /// @dev The only way value leaves this contract other than a surplus sweep. It is bounded by
    ///      the named account's own balance, so a controller cannot overdraw into another
    ///      account, nor into a stray transfer.
    function payOut(bytes32 kind, bytes32 key, address to, uint256 amount) external onlyController {
        require(to != address(0), unicode"Zero address / 零地址");
        bytes32 account = ownAccount(kind, key);
        uint256 have = balanceOf[account];
        require(have >= amount, unicode"Account is short / 账户余额不足");
        unchecked {
            balanceOf[account] = have - amount;
            totalAccounted -= amount;
        }
        asset.safeTransfer(to, amount);
        emit Paid(msg.sender, account, to, amount);
    }

    // -------------------------------------------------------------------------------------
    // Views and the surplus path
    // -------------------------------------------------------------------------------------

    /// @notice Tokens sitting here that the ledger has never attributed to anyone.
    /// @dev Anything above zero means a transfer arrived outside `deposit`. It is visible on
    ///      purpose: an unattributed balance that silently joined a payout is how a losing
    ///      position gets mistaken for a winning one.
    function unaccounted() public view returns (uint256) {
        uint256 held = asset.balanceOf(address(this));
        return held > totalAccounted ? held - totalAccounted : 0;
    }

    /// @notice The invariant this vault exists to hold. False means something is very wrong.
    function solvent() external view returns (bool) {
        return asset.balanceOf(address(this)) >= totalAccounted;
    }

    /// @notice How much of `token` this contract holds that the ledger has never attributed.
    /// @dev For `asset` that is the surplus over `totalAccounted`. For anything else it is the
    ///      whole balance: `balanceOf` is keyed by an account id, every account is denominated in
    ///      `asset`, and there is no code path that could ever credit a foreign token to one. A
    ///      caller can therefore read what a sweep would move before paying for it.
    function sweepable(IERC20 token) public view returns (uint256) {
        require(address(token) != address(0), unicode"Zero address / 零地址");
        if (token == asset) return unaccounted();
        return token.balanceOf(address(this));
    }

    /// @notice Native value held here. All of it is unaccounted; the ledger cannot denominate it.
    function sweepableNative() public view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Sends stray `asset` to the salvage address. Permissionless, and bounded to surplus.
    /// @dev Cannot reach accounted funds by construction: it moves exactly `unaccounted()`, and
    ///      the destination is immutable, so calling it confers nothing on the caller.
    function sweepUnaccounted() external nonReentrantSweep returns (uint256 amount) {
        return _sweepAsset();
    }

    /// @notice Sends a stray token to the salvage address. Permissionless.
    /// @dev Passing `asset` is not an error and is not a wider power: it routes to the same
    ///      surplus-only arithmetic as `sweepUnaccounted`, so there is exactly one rule at one
    ///      entry point and no argument that widens it.
    ///
    ///      For any other token the whole balance moves, and the post-condition is what makes
    ///      that safe rather than merely intended. Comparing addresses does not prove a token is
    ///      not `asset`: a token with a second entry point onto the same balance passes the
    ///      comparison and its `transfer` moves accounted funds. So instead of trusting the
    ///      comparison, this measures: if the sweep lowered this contract's `asset` balance by so
    ///      much as one wei, the whole call reverts. An alias cannot pass that, and neither can a
    ///      token whose `transfer` re-enters and tries to take the accounted side with it.
    function sweepToken(IERC20 token) external nonReentrantSweep returns (uint256 amount) {
        require(address(token) != address(0), unicode"Zero address / 零地址");
        if (token == asset) return _sweepAsset();

        uint256 assetHeldBefore = asset.balanceOf(address(this));
        amount = token.balanceOf(address(this));
        require(amount != 0, unicode"Nothing unaccounted / 无未入账余额");

        token.safeTransfer(salvage, amount);

        // The only line standing between a foreign-token sweep and an aliased `asset`.
        require(asset.balanceOf(address(this)) >= assetHeldBefore, unicode"Sweep touched the asset / 清扫动到了本币");

        emit SweptToken(address(token), salvage, amount);
    }

    /// @notice Sends stray native value to the salvage address. Permissionless.
    /// @dev There is no `receive` here, so this is not a deposit route being drained — it is the
    ///      recovery route for value that arrived by `selfdestruct` or as a block-reward
    ///      recipient, the two deliveries a contract cannot decline. None of it is accounted, so
    ///      all of it is sweepable. `salvage` must be able to accept a plain transfer; a
    ///      destination that reverts on receipt would strand native value here, which is the one
    ///      thing about the salvage address that is worth checking at deploy time.
    function sweepNative() external nonReentrantSweep returns (uint256 amount) {
        amount = address(this).balance;
        require(amount != 0, unicode"Nothing unaccounted / 无未入账余额");
        (bool ok,) = salvage.call{value: amount}("");
        require(ok, unicode"Native sweep failed / 原生币清扫失败");
        emit SweptNative(salvage, amount);
    }

    /// @dev The surplus-only branch, shared by both entry points so the rule cannot drift apart.
    function _sweepAsset() private returns (uint256 amount) {
        amount = unaccounted();
        require(amount != 0, unicode"Nothing unaccounted / 无未入账余额");
        asset.safeTransfer(salvage, amount);
        emit SweptUnaccounted(salvage, amount);
    }
}
