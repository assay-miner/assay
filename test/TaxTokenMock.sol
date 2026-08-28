// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/token/ERC20/extensions/ERC20Permit.sol";

/// @title TaxTokenMock
/// @notice Unit-test stand-in for the launched Flap tax token.
/// @dev The protocol has exactly one token: the taxed-V3 token the launch creates. It is minted
///      into the pool by the Portal, so a unit test cannot construct the real thing. This mock
///      matches the only two properties the contracts under test rely on — a fixed supply and an
///      untaxed wallet-to-wallet `transferFrom`, which the live token was measured to have.
contract TaxTokenMock is ERC20, ERC20Permit {
    constructor(address recipient, uint256 supply) ERC20("Assay", "ASSAY") ERC20Permit("Assay") {
        _mint(recipient, supply);
    }
}
