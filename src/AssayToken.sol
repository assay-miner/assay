// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title ASSAY
/// @notice Fixed-supply work token for the ASSAY optimisation tournaments.
/// @dev There is no mint function beyond the constructor and no owner. Mining rewards are not
///      inflation: they are paid out of a pre-funded reserve that the deployer transfers into
///      the tournament at launch, so the supply that exists at block zero is the supply that
///      will ever exist.
contract AssayToken is ERC20, ERC20Permit {
    uint256 public constant MAX_SUPPLY = 1_000_000_000e18;

    constructor(address recipient) ERC20("Assay", "ASSAY") ERC20Permit("Assay") {
        _mint(recipient, MAX_SUPPLY);
    }
}
