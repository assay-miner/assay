// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of the ERC-8004 Identity Registry that ASSAY depends on.
/// @dev Live and verified at the time of writing (`getVersion()` returns "2.0.0"):
///        BNB Smart Chain mainnet (56): 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
///        BNB Smart Chain testnet (97): 0x8004A818BFB912233c491871b3d84c89A494BD9e
///      Every selector below was resolved against the deployed bytecode, not guessed.
interface IIdentityRegistry {
    /// @notice True when `account` may act for `agentId` — either as the identity's ERC-721
    ///         owner or as a wallet the owner authorised via `setAgentWallet`.
    /// @dev This is what lets a miner run from a disposable hot key while the identity NFT
    ///      itself stays in cold storage. selector 0xd95e72be
    function isAuthorizedOrOwner(address account, uint256 agentId) external view returns (bool);

    /// @notice ERC-721 owner of the agent identity. selector 0x6352211e
    function ownerOf(uint256 agentId) external view returns (address);

    /// @notice Collection name; the canonical registry answers "AgentIdentity". selector 0x06fdde03
    function name() external view returns (string memory);

    /// @notice Registry version; the canonical registry answers "2.0.0". selector 0x0d8e6e2c
    /// @dev Load-bearing. On BNB Smart Chain *mainnet* the address that is the registry on
    ///      testnet also holds 130 bytes of code, but it is a different and incompatible
    ///      deployment that answers "0.0.1" here and reverts on `name()`. A has-code check
    ///      therefore does not distinguish the right registry from the wrong one — measured
    ///      directly against both addresses, not assumed.
    function getVersion() external view returns (string memory);
}
