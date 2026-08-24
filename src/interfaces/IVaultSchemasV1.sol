// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title IVaultSchemasV1
/// @notice The Flap protocol's self-describing UI schema types, reproduced verbatim.
///
/// @dev Why a protocol would describe its own interface on chain: a generic UI can call
///      `vaultUISchema()` on a contract that did not exist when the UI was written and render a
///      working page for it — no bespoke frontend, no listing process, no permission.
///
///      The rendering rule that matters most here: a view whose `isOutputArray` is true becomes
///      a paginated table or card list, and a write method alongside it becomes the button on
///      each row. A schema made only of scalar views renders as one flat column of numbers.
///
///      `approvals` is the other load-bearing part: a write method can declare that the UI must
///      send an ERC-20 `approve` first, naming which input field carries the amount, so a user
///      is never asked to approve by hand before a stake.
struct FieldDescriptor {
    string name;
    string fieldType;
    string description;
    uint8 decimals;
}

/// @notice An ERC-20 approve the UI must execute before sending a write method.
/// @param tokenType       "taxToken" or "lpToken" — resolved by calling that method on the vault.
/// @param amountFieldName The write method input whose value is the approve amount.
struct ApproveAction {
    string tokenType;
    string amountFieldName;
}

/// @notice One method the UI should render, as a query panel or an interactive form.
struct VaultMethodSchema {
    string name;
    string description;
    FieldDescriptor[] inputs;
    FieldDescriptor[] outputs;
    ApproveAction[] approvals;
    bool isInputArray;
    bool isOutputArray;
    bool isWriteMethod;
}

/// @notice The whole UI surface of a vault.
struct VaultUISchema {
    string vaultType;
    string description;
    VaultMethodSchema[] methods;
}
