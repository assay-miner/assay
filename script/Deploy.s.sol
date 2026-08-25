// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AssayToken} from "../src/AssayToken.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AssayFlapFactory} from "../src/AssayFlapFactory.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "../src/flap/IPortal.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ClonesUpgradeable} from "@openzeppelin-contracts-upgradeable/proxy/ClonesUpgradeable.sol";

/// @notice Deploys the ASSAY stack and writes a manifest the ops scripts read addresses out of.
/// @dev The ERC-8004 registry is resolved from the chain id rather than an environment variable,
///      so nobody can paste the wrong registry into a launch.
contract Deploy is Script {
    error UnsupportedChain(uint256 chainId);
    error NothingDeployed(string what, address where);
    error WrongRegistry(address where, string name, string version);
    error NoVanitySalt();
    error NoVaultCreated();

    /// @notice Where Flap's portal, its clone deployer and its taxed-V3 implementation live.
    /// @dev The implementation is what a vanity salt is mined against, and getting it wrong
    ///      silently predicts the wrong address. Both were read out of the EIP-1167 runtime of a
    ///      token Flap actually launched on that chain, not copied from a document:
    ///        56 → 0xE1B41ec0…7777 (WALLOPOLY)
    ///        97 → 0xddc053de…7777 ("test")
    ///      A wrong value still fails closed — the portal's real clone would land off 0x7777 and
    ///      the launch reverts InvalidVanity during simulation — but failing closed is the
    ///      backstop, not the plan.
    struct FlapVenue {
        address vaultPortal;
        address portal;
        address taxedV3Impl;
    }

    function flapVenueFor(uint256 chainId) public pure returns (FlapVenue memory v) {
        if (chainId == 56) {
            return FlapVenue({
                vaultPortal: 0x90497450f2a706f1951b5bdda52B4E5d16f34C06,
                portal: 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0,
                taxedV3Impl: 0x024f18294970B5c76c0691b87f138A0317156422
            });
        }
        if (chainId == 97) {
            return FlapVenue({
                vaultPortal: 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f,
                portal: 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9,
                taxedV3Impl: 0xE6Ff967a887084c16D0fD71548CF709542cc1557
            });
        }
        revert UnsupportedChain(chainId);
    }

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

    /// @dev Mines a salt whose predicted clone ends in 0x7777, which a taxed-V3 launch requires.
    ///      Starts from a caller-supplied offset because low offsets were swept years ago: the
    ///      portal rejects an already-staged address, and a fixed start would make every launch
    ///      from this script collide with the last one.
    function mineVanitySalt(FlapVenue memory v, uint256 from) public pure returns (bytes32 salt) {
        salt = bytes32(from);
        for (uint256 i; i < 4_000_000; ++i) {
            address predicted =
                ClonesUpgradeable.predictDeterministicAddress(v.taxedV3Impl, salt, v.portal);
            bytes20 a = bytes20(predicted);
            if (a[18] == 0x77 && a[19] == 0x77) return salt;
            salt = bytes32(uint256(salt) + 1);
        }
        revert NoVanitySalt();
    }

    /// @dev Every one of these was found by asking the portal rather than reading its interface:
    ///      the enums are documented, which member a taxed-V3 launch permits is not. FOUR_FIFTHS
    ///      is the only accepted threshold, and BNB needs V2_MIGRATOR.
    function launchParams(address factory, bytes32 salt, string memory name, string memory symbol)
        public
        pure
        returns (IVaultPortalTypes.NewTokenV6WithVaultParams memory p)
    {
        p.name = name;
        p.symbol = symbol;
        p.meta = "";
        p.dexThresh = IPortalCommonTypes.DexThreshType.FOUR_FIFTHS;
        p.salt = salt;
        p.migratorType = IPortalTypes.MigratorType.V2_MIGRATOR;
        p.quoteToken = address(0);
        p.quoteAmt = 0;
        p.dexId = IPortalTypes.DEXId.DEX0;
        p.buyTaxRate = 100;
        p.sellTaxRate = 100;
        p.taxDuration = 365 days;
        p.antiFarmerDuration = 30 days;
        p.mktBps = 10_000;
        p.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        p.vaultFactory = factory;
        p.vaultData = "";
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

        // Salvage is where a mistaken transfer into the vault can be swept. It can never reach
        // accounted funds, but it is still a named destination, so it is fixed at deploy.
        address salvage = vm.envOr("SALVAGE", deployer);

        vm.startBroadcast(pk);
        AssayToken token = new AssayToken(deployer);
        AssayVault vault = new AssayVault(IERC20(address(token)), salvage);
        AgentRoster roster = new AgentRoster(IIdentityRegistry(registry), vault, minStake, deployer);
        Tournament tournament = new Tournament(vault, roster, deployer);

        // Custody wiring, then sealed. After `freeze()` no address can be added to the vault.
        vault.addController(address(roster));
        vault.addController(address(tournament));
        vault.freeze();

        roster.setConsumer(address(tournament));

        // The token layer. A protocol whose prize money comes from a token's trading tax is not
        // launched until that token exists, so this is part of the launch and not a second
        // errand — which also means the vault address is chained into the manifest instead of
        // being read off a console and pasted somewhere later.
        // The factory is part of the stack, not part of the token launch. Skipping the launch and
        // skipping the factory were the same flag once, so a deploy that deliberately held the
        // token back also produced no factory — and the factory is the contract Flap audits.
        FlapVenue memory venue = flapVenueFor(block.chainid);
        address flapFactory = address(new AssayFlapFactory(tournament));
        address taxToken;
        address flapVault;

        if (!vm.envOr("SKIP_TOKEN", false)) {
            bytes32 salt = mineVanitySalt(
                venue,
                vm.envOr("SALT_OFFSET", uint256(keccak256(abi.encode("assay.v1", deployer))))
            );
            taxToken = IVaultPortal(payable(venue.vaultPortal)).newTokenV6WithVault{value: 0}(
                launchParams(
                    flapFactory,
                    salt,
                    vm.envOr("TOKEN_NAME", string("Assay")),
                    vm.envOr("TOKEN_SYMBOL", string("ASSAY"))
                )
            );
            flapVault = IVaultPortal(payable(venue.vaultPortal)).getVault(taxToken).vault;
            if (flapVault == address(0)) revert NoVaultCreated();
        }

        vm.stopBroadcast();

        // A manifest is written even when a broadcast silently lands nothing. Prove the code is
        // actually on chain before recording it as deployed.
        if (address(token).code.length == 0) revert NothingDeployed("AssayToken", address(token));
        if (address(roster).code.length == 0) revert NothingDeployed("AgentRoster", address(roster));
        if (address(tournament).code.length == 0) {
            revert NothingDeployed("Tournament", address(tournament));
        }
        if (address(vault).code.length == 0) revert NothingDeployed("AssayVault", address(vault));
        require(roster.consumer() == address(tournament), "consumer not wired");
        require(roster.consumerFrozen(), "consumer not frozen");
        require(vault.isController(address(roster)), "roster not a vault controller");
        require(vault.isController(address(tournament)), "tournament not a vault controller");
        require(vault.controllersFrozen(), "vault controllers not frozen");
        require(vault.solvent(), "vault must start solvent");

        // Same rule for the token layer: a returned address is a simulation result until the
        // chain has code at it.
        if (flapVault != address(0)) {
            if (flapVault.code.length == 0) revert NothingDeployed("AssayFlapVault", flapVault);
            if (taxToken.code.length == 0) revert NothingDeployed("taxToken", taxToken);
            require(
                AssayFlapVault(payable(flapVault)).taxToken() == taxToken,
                "vault is bound to a different token"
            );
            require(
                address(AssayFlapVault(payable(flapVault)).tournament()) == address(tournament),
                "vault settles against a different tournament"
            );
            require(AssayFlapVault(payable(flapVault)).solvent(), "flap vault must start solvent");
        }

        string memory json = "manifest";
        vm.serializeUint(json, "chainId", block.chainid);
        // Where to start scanning for this tournament's events. Without it a client has to ask
        // for the whole chain, which every public node refuses — so the feature that reads
        // rivals' revealed bytecode degraded to nothing and said so in a line nobody acted on.
        vm.serializeUint(json, "deployBlock", block.number);
        vm.serializeAddress(json, "deployer", deployer);
        vm.serializeAddress(json, "identityRegistry", registry);
        vm.serializeAddress(json, "token", address(token));
        vm.serializeAddress(json, "vault", address(vault));
        vm.serializeAddress(json, "salvage", salvage);
        vm.serializeAddress(json, "roster", address(roster));
        vm.serializeUint(json, "minStake", minStake);
        vm.serializeUint(json, "maxSupply", token.MAX_SUPPLY());
        vm.serializeAddress(json, "flapFactory", flapFactory);
        vm.serializeAddress(json, "taxToken", taxToken);
        vm.serializeAddress(json, "flapVault", flapVault);
        string memory out = vm.serializeAddress(json, "tournament", address(tournament));

        string memory path =
            string.concat("deployments/", vm.toString(block.chainid), "-latest.json");
        vm.writeJson(out, path);

        console2.log("chainId          ", block.chainid);
        console2.log("deployer         ", deployer);
        console2.log("identityRegistry ", registry);
        console2.log("token            ", address(token));
        console2.log("vault            ", address(vault));
        console2.log("salvage          ", salvage);
        console2.log("roster           ", address(roster));
        console2.log("tournament       ", address(tournament));
        console2.log("flapFactory      ", flapFactory);
        console2.log("taxToken         ", taxToken);
        console2.log("flapVault        ", flapVault);
        console2.log("manifest         ", path);
    }
}
