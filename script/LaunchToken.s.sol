// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Deploy} from "./Deploy.s.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {IVaultPortal} from "../src/flap/IVaultPortal.sol";

/// @notice Launches a tax token through an already-deployed factory.
///
/// @dev Until now the only way to get a token was to redeploy the whole stack, which is both
///      wasteful and wrong: the factory is the audited artifact, and replacing it to change a
///      launch parameter throws away the address an auditor verified. A launch parameter belongs
///      to the launch, so this reuses the factory and only does the part that has to be new.
///
///      The salt has to be mined for a 0x7777 suffix and cannot repeat: the portal refuses an
///      address it has already staged, so SALT_OFFSET must differ from any previous launch by
///      this deployer. It is derived from the token symbol by default, which makes a second
///      launch of the same symbol fail loudly rather than silently reuse a staged address.
contract LaunchToken is Script {
    error NoFactory();
    error NoVaultCreated();

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        Deploy helper = new Deploy();

        string memory path =
            string.concat("deployments/", vm.toString(block.chainid), "-latest.json");
        string memory manifest = vm.readFile(path);
        address factory = vm.parseJsonAddress(manifest, ".flapFactory");
        if (factory == address(0) || factory.code.length == 0) revert NoFactory();

        string memory name = vm.envOr("TOKEN_NAME", string("Assay"));
        string memory symbol = vm.envOr("TOKEN_SYMBOL", string("ASSAY"));

        Deploy.FlapVenue memory venue = helper.flapVenueFor(block.chainid);
        // `SALT` skips mining. It is pure but slow, and a public BSC node prunes state out from
        // under a fork that stays open that long — the launch then fails with `missing trie node`,
        // which reads like a bug and is not one. script/MineSalt.s.sol produces one offline.
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        if (salt == bytes32(0)) {
            salt = helper.mineVanitySalt(
                helper.flapVenueFor(block.chainid),
                vm.envOr("SALT_OFFSET", uint256(keccak256(abi.encode(symbol, vm.addr(pk)))))
            );
        }

        vm.startBroadcast(pk);
        address taxToken = IVaultPortal(payable(venue.vaultPortal)).newTokenV6WithVault{value: 0}(
            helper.launchParams(factory, salt, name, symbol)
        );
        vm.stopBroadcast();

        address flapVault = IVaultPortal(payable(venue.vaultPortal)).getVault(taxToken).vault;
        if (flapVault == address(0)) revert NoVaultCreated();

        // Proven on chain before it is written down: a returned address is a simulation result
        // until the chain has code at it.
        require(taxToken.code.length > 0, "tax token has no code");
        require(flapVault.code.length > 0, "vault has no code");
        require(AssayFlapVault(payable(flapVault)).taxToken() == taxToken, "vault bound elsewhere");

        console2.log("taxToken   ", taxToken);
        console2.log("flapVault  ", flapVault);
        console2.log("factory    ", factory);
    }
}
