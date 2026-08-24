// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";

/// @notice Stand-in for the ERC-8004 Identity Registry in unit tests.
/// @dev The fork test in `test/ForkIdentity.t.sol` is what proves the real registry answers the
///      same two calls the same way; this mock only keeps unit tests off the network.
contract MockIdentityRegistry is IIdentityRegistry {
    mapping(uint256 => address) private _owner;
    mapping(uint256 => mapping(address => bool)) private _authorized;

    function mint(uint256 agentId, address to) external {
        _owner[agentId] = to;
    }

    function authorize(uint256 agentId, address account, bool ok) external {
        _authorized[agentId][account] = ok;
    }

    function isAuthorizedOrOwner(address account, uint256 agentId) external view returns (bool) {
        return _owner[agentId] == account || _authorized[agentId][account];
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        return _owner[agentId];
    }
}
