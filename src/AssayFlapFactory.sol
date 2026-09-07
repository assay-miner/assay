// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactory} from "./flap/IVaultFactory.sol";
import {VaultDataSchema, FieldDescriptor} from "./flap/IVaultSchemasV1.sol";
import {AssayFlapVault} from "./AssayFlapVault.sol";
import {Tournament} from "./Tournament.sol";
import {PriceGuard} from "./PriceGuard.sol";

/// @title AssayFlapFactory
/// @notice Creates an ASSAY vault when a token is launched through Flap's VaultPortal.
///
/// @dev Registration is not required to launch: the portal's own documentation says any factory
///      may be used, and an unregistered one simply produces a vault marked unofficial with an
///      UNVERIFIED risk level. Registration is Flap's endorsement, not their permission — which
///      means this can ship without waiting on anybody, and be endorsed later.
///
///      The factory is deliberately thin. It holds no funds, decides nothing about rewards, and
///      exists only to bind a freshly-launched tax token to a vault that already knows which
///      tournament it settles against.
///
///      It is itself deployed behind a beacon proxy, which is what Flap requires of every
///      contract on their platform: the upgrade authority is the Guardian's beacon, not anything
///      in here. There is deliberately no upgrade function and no owner on this implementation.
contract AssayFlapFactory is VaultFactoryBaseV2, Initializable {
    /// @notice The tournament every vault this factory creates will pay against.
    /// @dev Storage rather than `immutable` because an implementation behind a proxy has no
    ///      constructor of its own to burn a value into: the proxy's storage is the only place a
    ///      value set at initialization can live. The declaration order of the three below is
    ///      permanent — a later implementation that reorders them reads other variables' values.
    Tournament public tournament;

    /// @notice Prices every vault this factory creates. Fixed here so no vault is ever handed a
    ///         pricing contract by whoever launched its token.
    PriceGuard public priceGuard;

    /// @notice The beacon each created vault points at, and therefore the authority that may
    ///         upgrade every vault this factory has ever made.
    /// @dev This slot used to hold an `AssayVaultDeployer`, constructed here, whose only purpose
    ///      was EIP-170: `new AssayFlapVault(...)` written inside `newVault` put the vault's whole
    ///      21,789-byte creation code into this factory's *runtime*, which is what the
    ///      24,576-byte limit measures. A `BeaconProxy`'s creation code is a few dozen bytes, so
    ///      the pressure that contract was invented to relieve no longer exists and the contract
    ///      goes with it.
    ///
    ///      Supplied to `initialize` rather than built here, because a beacon has to outlive the
    ///      implementation that points at it. One this factory constructed for itself would be a
    ///      new beacon — and so a severed upgrade path for every vault already created — every
    ///      time the factory implementation changed.
    address public vaultBeacon;

    event VaultCreated(address indexed vault, address indexed taxToken, address indexed creator);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // The implementation is never used directly; only proxies delegatecall into it. Locking it
        // means nobody can initialize the implementation itself and pose as this factory.
        _disableInitializers();
    }

    /// @notice Binds this factory to its tournament, its price guard and its vault beacon.
    ///
    /// @dev This is the old constructor, moved. Construction guaranteed single execution for free;
    ///      behind a beacon proxy there is no constructor to run, and `initializer` is what now
    ///      carries that guarantee — it is the whole reason the three values below can still be
    ///      read as fixed rather than as settable state.
    ///
    ///      The two address checks are the constructor's, unchanged. They matter for the same
    ///      reason they always did: a factory holding a zero here mints vaults that point at
    ///      nothing, and that is discovered at somebody's token launch rather than at deployment.
    function initialize(Tournament tournament_, PriceGuard priceGuard_, address vaultBeacon_)
        external
        initializer
    {
        require(address(priceGuard_) != address(0), unicode"PriceGuard address is zero / 定价合约地址为零");
        priceGuard = priceGuard_;
        require(address(tournament_) != address(0), unicode"Tournament address is zero / 锦标赛地址为零");
        tournament = tournament_;
        // The one check the constructor did not need: `new AssayVaultDeployer()` could not return
        // zero, an argument can. Same reasoning as the two above, applied to the value that
        // replaced it.
        require(vaultBeacon_ != address(0), unicode"Vault beacon address is zero / 金库信标地址为零");
        vaultBeacon = vaultBeacon_;
    }

    /// @inheritdoc IVaultFactory
    /// @dev `taxToken` does not exist yet — the portal predicts its address, creates the vault,
    ///      then creates the token. So this must not call into the token; it only records it.
    function newVault(address taxToken, address, address creator, bytes calldata)
        external
        override
        returns (address vault)
    {
        // Only the portal may create vaults here. Otherwise anybody could mint a vault claiming
        // to belong to a token they do not control, and a UI reading `taxToken()` would believe it.
        require(
            msg.sender == _getVaultPortal(),
            unicode"Only the vault portal may create a vault / 只有金库门户可以创建金库"
        );

        // Deployed and initialized in one call, so there is no block in which a vault exists with
        // an unset tournament for somebody else to claim. The arguments are exactly the ones the
        // vault's constructor took, in the order it took them; nothing about the vault's own
        // configuration is decided here, and nothing is supplied by the launcher.
        vault = address(
            new BeaconProxy(
                vaultBeacon,
                abi.encodeCall(AssayFlapVault.initialize, (tournament, taxToken, creator, priceGuard))
            )
        );
        emit VaultCreated(vault, taxToken, creator);
    }

    /// @inheritdoc IVaultFactory
    /// @dev Native BNB only. The vault's revenue is native, and accepting a quote token whose
    ///      revenue arrives as ERC-20 would leave the vault holding something it cannot pay out.
    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool) {
        return quoteToken == address(0);
    }

    /// @notice This factory needs no launch-time configuration, and says so.
    /// @dev An empty field list tells the launch UI to render no extra form.
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = unicode"No configuration needed. The vault settles against the ASSAY tournament and turns this token's trading tax into prize money for verified gas-optimisation work. / 无需配置。金库对接 ASSAY 锦标赛,把本代币的交易税变成可验证优化工作的奖金。";
        schema.fields = new FieldDescriptor[](0);
        schema.isArray = false;
    }

    /// @dev Room for a later implementation to add state without landing on top of anything
    ///      declared below this contract. Storage behind a beacon is permanent; the gap is what
    ///      makes the next version's variables free to exist.
    uint256[50] private __gap;
}
