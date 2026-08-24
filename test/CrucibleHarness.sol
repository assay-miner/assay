// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Crucible} from "../src/Crucible.sol";

/// @notice Exposes the Crucible internals so tests can calibrate a baseline the same way a task
///         author would: by measuring a reference implementation.
contract CrucibleHarness {
    function measure(bytes memory runtime, Crucible.Vector[] memory vectors, uint256 gasCap)
        external
        returns (bool ok, uint256 gasUsed, address impl)
    {
        impl = Crucible.deployRuntime(runtime);
        (ok, gasUsed) = Crucible.assay(impl, vectors, gasCap);
    }

    function deployOnly(bytes memory runtime) external returns (address) {
        return Crucible.deployRuntime(runtime);
    }
}
