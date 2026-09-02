// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AssayFlapVault} from "./AssayFlapVault.sol";
import {Tournament} from "./Tournament.sol";
import {PriceGuard} from "./PriceGuard.sol";

/// @notice Holds the vault's creation code so the factory does not have to.
///
/// @dev This exists for one reason: EIP-170. `new AssayFlapVault(...)` written inside the factory's
///      `newVault` puts the vault's entire creation code — 21,789 bytes — into the factory's
///      *runtime*, which is what the 24,576-byte limit measures. The factory's own logic is about
///      2,600 bytes, so the vault was using 89% of the factory's budget and every audit round that
///      added a require string or a bilingual label spent it down further. It reached 345 bytes of
///      headroom, at which point trimming labels stops being an engineering answer.
///
///      Constructed by the factory, in the factory's constructor. That placement is the whole
///      trick: code reached by `new` from a constructor lives in the *creation* code, which EIP-170
///      does not measure and EIP-3860 caps far higher at 49,152. It also settles the ownership
///      question without a setter — `msg.sender` at construction is the factory, permanently, so
///      there is no address for anyone to supply and nothing to re-point later.
///
///      The guard matters. Without it anyone could deploy a vault naming any token and any creator;
///      such a vault is orphaned, since only the portal routes tax, but it would be indistinguishable
///      on chain from a real one and that is a griefing surface nobody needs.
contract AssayVaultDeployer {
    /// @notice The factory that created this, and the only account that may deploy through it.
    address public immutable factory;

    constructor() {
        factory = msg.sender;
    }

    /// @notice Deploys one vault. Callable only by the factory that constructed this contract.
    function deploy(Tournament tournament, address taxToken, address creator, PriceGuard priceGuard)
        external
        returns (address vault)
    {
        require(msg.sender == factory, unicode"Only the factory / 仅限工厂");
        vault = address(new AssayFlapVault(tournament, taxToken, creator, priceGuard));
    }
}
