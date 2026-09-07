// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Deploy} from "./Deploy.s.sol";
import {ClonesUpgradeable} from "@openzeppelin-contracts-upgradeable/proxy/ClonesUpgradeable.sol";

/// @notice Mines the vanity salt offline, so the deploy itself holds a fork open for seconds.
contract MineSalt is Deploy {
    function mine() external view {
        uint256 chainId = vm.envOr("CHAIN", uint256(56));
        FlapVenue memory venue = flapVenueFor(chainId);
        // With SALT set this only predicts, so a caller can ask "where does this salt land?"
        // without mining a different one and printing an address it will never deploy to.
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        if (salt == bytes32(0)) {
            // NOT 1. Scanning from a fixed low offset returns the first vanity hit on the venue,
            // which is the one everybody else's identical scan returns too — 0x2dc5c on BSC
            // mainnet, taken since block 98,443,003. `Deploy` already derived its offset from the
            // deployer; this script, which is what an operator actually runs, did not. Same
            // derivation here, so the two call sites cannot disagree again.
            salt = mineVanitySalt(
                venue,
                vm.envOr("SALT_OFFSET", uint256(keccak256(abi.encode("assay.v1", vm.envAddress("DEPLOYER")))))
            );
        }
        address predicted =
            ClonesUpgradeable.predictDeterministicAddress(venue.taxedV3Impl, salt, venue.portal);
        console2.log("SALT ", vm.toString(salt));
        console2.log("token", predicted);
    }
}
