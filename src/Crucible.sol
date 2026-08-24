// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Crucible
/// @notice Deploys miner-submitted EVM runtime bytecode and assays it against a task's test
///         vectors, returning whether every vector produced the expected output and how much
///         gas the submission burned doing so.
///
/// @dev Two properties make it safe to execute an adversary's bytecode here:
///
///      1. The submission never runs a constructor. `deployRuntime` wraps the payload in a
///         fixed 14-byte prologue that does nothing but CODECOPY the payload into return data.
///         An attacker therefore has no deployment-time execution window at all.
///
///      2. The submission is only ever reached through STATICCALL with an explicit gas cap.
///         It cannot write storage, emit logs, send value, selfdestruct, or reenter anything
///         that mutates state, and it cannot burn more than `gasCap` of the caller's gas.
///
///      The gas figure is read immediately either side of the STATICCALL, before any of this
///      library's own bookkeeping runs, so the number attributed to a miner is the cost of
///      their code plus one call opcode — the same constant for every miner on a task.
library Crucible {
    /// @notice EIP-170 runtime code size limit. A payload above this cannot be deployed at all,
    ///         so it is rejected explicitly rather than left to a bare CREATE failure.
    uint256 internal constant MAX_RUNTIME = 24_576;

    /// @notice Head-room multiplier protecting a miner from a caller who under-funds the reveal.
    /// @dev EIP-150 forwards at most 63/64 of the remaining gas, so a probe needs strictly more
    ///      than `gasCap` left on the frame to actually receive `gasCap`.
    uint256 internal constant GAS_HEADROOM_NUM = 66;
    uint256 internal constant GAS_HEADROOM_DEN = 64;

    struct Vector {
        /// @notice Raw calldata handed to the submission.
        bytes input;
        /// @notice keccak256 of the return data the submission must produce.
        /// @dev Only the hash is stored. A submission cannot read the answer out of the
        ///      tournament's storage and echo it back; it has to produce the preimage.
        bytes32 expected;
    }

    error RuntimeEmpty();
    error RuntimeTooLarge(uint256 size);
    error DeployFailed();
    error InsufficientGas(uint256 available, uint256 required);

    /// @notice Deploys `runtime` verbatim as a contract with no constructor execution.
    /// @param runtime The exact bytes that will become the deployed contract's code.
    /// @return impl Address of the deployed submission.
    function deployRuntime(bytes memory runtime) internal returns (address impl) {
        uint256 n = runtime.length;
        if (n == 0) revert RuntimeEmpty();
        if (n > MAX_RUNTIME) revert RuntimeTooLarge(n);

        // PUSH4 n | DUP1 | PUSH1 14 | PUSH1 0 | CODECOPY | PUSH1 0 | RETURN
        // 14 bytes of prologue, then the payload. Copies payload to memory[0..n] and returns it.
        bytes memory initcode = abi.encodePacked(hex"63", uint32(n), hex"80600E6000396000F3", runtime);

        assembly ("memory-safe") {
            impl := create(0, add(initcode, 0x20), mload(initcode))
        }
        if (impl == address(0)) revert DeployFailed();
    }

    /// @notice Runs every vector against `impl` and totals the gas burned.
    /// @dev Returns `(false, 0)` the moment any vector reverts or returns the wrong bytes, so a
    ///      partially-correct submission is worth exactly as much as a wrong one.
    /// @param impl The deployed submission.
    /// @param vectors The task's test vectors.
    /// @param gasCap Per-vector gas ceiling.
    /// @return ok True only if every vector produced the expected output.
    /// @return gasUsed Total gas across all vectors; meaningless when `ok` is false.
    function assay(address impl, Vector[] memory vectors, uint256 gasCap)
        internal
        view
        returns (bool ok, uint256 gasUsed)
    {
        uint256 count = vectors.length;

        // Fail loudly rather than let an under-funded call silently starve a correct submission
        // into looking like a failing one.
        uint256 required = (count * gasCap * GAS_HEADROOM_NUM) / GAS_HEADROOM_DEN + 50_000;
        if (gasleft() < required) revert InsufficientGas(gasleft(), required);

        uint256 total;
        for (uint256 i; i < count; ++i) {
            (bool success, bytes32 outHash, uint256 g) = _probe(impl, vectors[i].input, gasCap);
            if (!success || outHash != vectors[i].expected) return (false, 0);
            total += g;
        }
        return (true, total);
    }

    /// @dev Single metered STATICCALL. `gasUsed` is sampled before any return-data handling so
    ///      the miner is never charged for this library's own memory expansion.
    function _probe(address impl, bytes memory input, uint256 gasCap)
        private
        view
        returns (bool success, bytes32 outHash, uint256 gasUsed)
    {
        assembly ("memory-safe") {
            // Scratch above the free pointer. Deliberately not published: the hash is consumed
            // here and the bytes never need to outlive this frame.
            let scratch := mload(0x40)
            let g0 := gas()
            success := staticcall(gasCap, impl, add(input, 0x20), mload(input), 0, 0)
            gasUsed := sub(g0, gas())
            let n := returndatasize()
            returndatacopy(scratch, 0, n)
            outHash := keccak256(scratch, n)
        }
    }
}
