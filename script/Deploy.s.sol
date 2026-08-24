// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AssayToken} from "../src/AssayToken.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys the ASSAY stack and writes a manifest the ops scripts read addresses out of.
/// @dev The ERC-8004 registry is resolved from the chain id rather than an environment variable,
///      so nobody can paste the wrong registry into a launch.
contract Deploy is Script {
    error UnsupportedChain(uint256 chainId);
    error NothingDeployed(string what, address where);
    error WrongRegistry(address where, string name, string version);

    string internal constant EXPECTED_REGISTRY_NAME = "AgentIdentity";
    string internal constant EXPECTED_REGISTRY_VERSION = "2.0.0";

    function registryFor(uint256 chainId) public pure returns (address) {
        if (chainId == 56) return 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
        if (chainId == 97) return 0x8004A818BFB912233c491871b3d84c89A494BD9e;
        revert UnsupportedChain(chainId);
    }

    /// @dev Fails closed: an unreadable name() or a version that is not the one this code was
    ///      written against both abort the launch.
    function assertCanonicalRegistry(address registry) public view {
        (bool nameOk, bytes memory nameRet) =
            registry.staticcall(abi.encodeWithSelector(IIdentityRegistry.name.selector));
        (bool verOk, bytes memory verRet) =
            registry.staticcall(abi.encodeWithSelector(IIdentityRegistry.getVersion.selector));

        string memory gotName = nameOk && nameRet.length > 0 ? abi.decode(nameRet, (string)) : "";
        string memory gotVer = verOk && verRet.length > 0 ? abi.decode(verRet, (string)) : "";

        if (
            keccak256(bytes(gotName)) != keccak256(bytes(EXPECTED_REGISTRY_NAME))
                || keccak256(bytes(gotVer)) != keccak256(bytes(EXPECTED_REGISTRY_VERSION))
        ) {
            revert WrongRegistry(registry, gotName, gotVer);
        }
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address registry = registryFor(block.chainid);

        // Having code is NOT enough to identify the registry. On mainnet the *testnet* registry
        // address also holds 130 bytes of code, answers getVersion() = "0.0.1", and reverts on
        // name() -- so a paste of the wrong address lands on a real-but-incompatible contract
        // instead of failing cleanly. Identify it by what it answers, not by whether it exists.
        if (registry.code.length == 0) revert NothingDeployed("identityRegistry", registry);
        assertCanonicalRegistry(registry);

        uint256 minStake = vm.envOr("MIN_STAKE", uint256(1_000e18));

        vm.startBroadcast(pk);
        AssayToken token = new AssayToken(deployer);
        AgentRoster roster =
            new AgentRoster(IIdentityRegistry(registry), IERC20(address(token)), minStake, deployer);
        Tournament tournament = new Tournament(IERC20(address(token)), roster, deployer);
        roster.setConsumer(address(tournament));
        vm.stopBroadcast();

        // A manifest is written even when a broadcast silently lands nothing. Prove the code is
        // actually on chain before recording it as deployed.
        if (address(token).code.length == 0) revert NothingDeployed("AssayToken", address(token));
        if (address(roster).code.length == 0) revert NothingDeployed("AgentRoster", address(roster));
        if (address(tournament).code.length == 0) {
            revert NothingDeployed("Tournament", address(tournament));
        }
        require(roster.consumer() == address(tournament), "consumer not wired");
        require(roster.consumerFrozen(), "consumer not frozen");

        string memory json = "manifest";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "deployer", deployer);
        vm.serializeAddress(json, "identityRegistry", registry);
        vm.serializeAddress(json, "token", address(token));
        vm.serializeAddress(json, "roster", address(roster));
        vm.serializeUint(json, "minStake", minStake);
        vm.serializeUint(json, "maxSupply", token.MAX_SUPPLY());
        string memory out = vm.serializeAddress(json, "tournament", address(tournament));

        string memory path =
            string.concat("deployments/", vm.toString(block.chainid), "-latest.json");
        vm.writeJson(out, path);

        console2.log("chainId          ", block.chainid);
        console2.log("deployer         ", deployer);
        console2.log("identityRegistry ", registry);
        console2.log("token            ", address(token));
        console2.log("roster           ", address(roster));
        console2.log("tournament       ", address(tournament));
        console2.log("manifest         ", path);
    }
}
