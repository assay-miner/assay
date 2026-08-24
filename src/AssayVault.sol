// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
///      The one deliberate exception is `sweepUnaccounted`, which can move *only* the surplus of
///      the real token balance over `totalAccounted` — tokens somebody sent here by mistake, that
///      the ledger has never attributed to anyone — and only ever to an address fixed at
///      deployment. It is bounded by arithmetic, not by trust, and it exists so a fat-fingered
///      transfer is recoverable instead of stranded here forever.
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

    error NotDeployer();
    error AlreadyFrozen();
    error NotFrozen();
    error NotController(address caller);
    error ZeroAddress();
    error InsufficientAccount(bytes32 account, uint256 have, uint256 want);
    error NothingUnaccounted();

    constructor(IERC20 asset_, address salvage_) {
        if (address(asset_) == address(0) || salvage_ == address(0)) revert ZeroAddress();
        asset = asset_;
        salvage = salvage_;
        deployer = msg.sender;
    }

    modifier onlyController() {
        if (!isController[msg.sender]) revert NotController(msg.sender);
        _;
    }

    // -------------------------------------------------------------------------------------
    // Wiring — done once, at deploy, then sealed
    // -------------------------------------------------------------------------------------

    /// @notice Names a contract allowed to hold accounts here.
    /// @dev Only callable before freezing, and freezing is irreversible. After `freeze()` the
    ///      controller set is part of the deployment rather than a setting.
    function addController(address controller) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (controllersFrozen) revert AlreadyFrozen();
        if (controller == address(0)) revert ZeroAddress();
        isController[controller] = true;
        emit ControllerAdded(controller);
    }

    /// @notice Seals the controller set forever.
    function freeze() external {
        if (msg.sender != deployer) revert NotDeployer();
        if (controllersFrozen) revert AlreadyFrozen();
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
        if (have < amount) revert InsufficientAccount(from, have, amount);
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
        if (to == address(0)) revert ZeroAddress();
        bytes32 account = ownAccount(kind, key);
        uint256 have = balanceOf[account];
        if (have < amount) revert InsufficientAccount(account, have, amount);
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

    /// @notice Sends stray tokens to the salvage address. Permissionless, and bounded to surplus.
    /// @dev Cannot reach accounted funds by construction: it moves exactly `unaccounted()`, and
    ///      the destination is immutable, so calling it confers nothing on the caller.
    function sweepUnaccounted() external returns (uint256 amount) {
        amount = unaccounted();
        if (amount == 0) revert NothingUnaccounted();
        asset.safeTransfer(salvage, amount);
        emit SweptUnaccounted(salvage, amount);
    }
}
