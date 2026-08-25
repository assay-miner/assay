// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactory} from "./flap/IVaultFactory.sol";
import {VaultDataSchema, FieldDescriptor} from "./flap/IVaultSchemasV1.sol";
import {AssayFlapVault} from "./AssayFlapVault.sol";
import {Tournament} from "./Tournament.sol";

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
contract AssayFlapFactory is VaultFactoryBaseV2 {
    /// @notice The tournament every vault this factory creates will pay against.
    Tournament public immutable tournament;

    event VaultCreated(address indexed vault, address indexed taxToken, address indexed creator);

    constructor(Tournament tournament_) {
        require(address(tournament_) != address(0), unicode"Tournament address is zero / 锦标赛地址为零");
        tournament = tournament_;
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

        vault = address(new AssayFlapVault(tournament, taxToken, creator));
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
}
