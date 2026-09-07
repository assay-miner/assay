// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ClonesUpgradeable} from "@openzeppelin-contracts-upgradeable/proxy/ClonesUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import {Stack} from "./Stack.sol";
import {TaxTokenMock} from "../test/TaxTokenMock.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapFactory} from "../src/AssayFlapFactory.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "../src/flap/IPortal.sol";

/// @notice Stands the whole thing up against Flap's real contracts, end to end.
///
/// @dev Intended to be run against a fork of BNB Smart Chain mainnet, where Flap's portal, its
///      taxed-V3 token implementation and its guardian all exist as they really are. It launches
///      a token through that portal using our own factory — which Flap has never registered —
///      and leaves behind a vault that a schema-driven UI can render.
///
///      Every launch parameter here was determined by asking the portal, not by reading the
///      interface: FOUR_FIFTHS is the only accepted dex threshold for a taxed-V3 launch, BNB
///      needs V2_MIGRATOR, and the salt has to be mined for a 0x7777 suffix from an offset
///      nobody has already swept.
contract FlapDemo is Script {
    /// @dev This fixture never posts on the drawn lane, so the generator is a placeholder.
    ///      Naming it says that on purpose rather than leaving a bare address to be read as real.
    address internal constant NO_DRAWN_LANE = address(0xDEAD);

    address payable constant VAULT_PORTAL = payable(0x90497450f2a706f1951b5bdda52B4E5d16f34C06);
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    address constant TOKEN_IMPL_TAXED_V3 = 0x024f18294970B5c76c0691b87f138A0317156422;
    address constant IDENTITY_REGISTRY_56 = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;

    function _mineVanitySalt(uint256 from) internal pure returns (bytes32 salt) {
        salt = bytes32(from);
        for (uint256 i; i < 4_000_000; ++i) {
            address predicted =
                ClonesUpgradeable.predictDeterministicAddress(TOKEN_IMPL_TAXED_V3, salt, PORTAL);
            bytes20 a = bytes20(predicted);
            if (a[18] == 0x77 && a[19] == 0x77) return salt;
            salt = bytes32(uint256(salt) + 1);
        }
        revert("no vanity salt found");
    }

    function _params(address factory, bytes32 salt)
        internal
        pure
        returns (IVaultPortalTypes.NewTokenV6WithVaultParams memory p)
    {
        p.name = "Assay";
        p.symbol = "ASSAY";
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
        address me = vm.addr(pk);

        vm.startBroadcast(pk);

        TaxTokenMock token = new TaxTokenMock(me, 1_000_000_000e18);

        // Every contract is now an implementation behind a beacon Flap's Guardian owns, and every
        // piece goes up through script/Stack.sol so this script cannot drift from Deploy.s.sol over
        // how any one of them is assembled. Not `Stack.deploy` though: that builds the real
        // tournament/generator cycle, and this fixture wants NO_DRAWN_LANE in the generator slot.
        // The typed helpers are what let it keep saying that.
        //
        // The Guardian comes from `Stack.guardian()` rather than a constant here. This script only
        // ever runs against a fork of chain 56, so a local constant would be right — but it would
        // be a second copy of a fact whose wrong value is not a failing test, it is a beacon
        // nobody at Flap can upgrade.
        address guardian = Stack.guardian();
        AssayVault custody = Stack.newVault(guardian, address(token), me, me);
        AgentRoster roster = Stack.newRoster(guardian, IDENTITY_REGISTRY_56, custody, 1000e18, me);
        Tournament tournament = Stack.newTournament(guardian, custody, roster, me, NO_DRAWN_LANE);
        custody.addController(address(roster));
        custody.addController(address(tournament));
        custody.freeze();
        roster.setConsumer(address(tournament));

        // The factory no longer carries the vault's creation code — it carries a beacon and creates
        // a BeaconProxy per launch — so the beacon has to exist before the factory does. It gets an
        // implementation and a beacon but no proxy of its own, which is why this is the one place
        // that does not go through a `Stack.new*` helper: every helper ends in an initialized
        // proxy, and a proxy here would be a second vault bound to a token that does not exist yet.
        // The only vault proxy that should ever exist is the one Flap's portal makes this factory
        // mint below, against the token it is about to create.
        PriceGuard priceGuard = Stack.newPriceGuard(guardian);
        address flapVaultBeacon =
            address(new UpgradeableBeacon(address(new AssayFlapVault()), guardian));
        AssayFlapFactory factory =
            Stack.newFactory(guardian, tournament, priceGuard, flapVaultBeacon);

        bytes32 salt = _mineVanitySalt(uint256(keccak256(abi.encode("assay.demo", block.number))));
        address taxToken = IVaultPortal(VAULT_PORTAL).newTokenV6WithVault{value: 0}(
            _params(address(factory), salt)
        );

        vm.stopBroadcast();

        IVaultPortalTypes.VaultInfo memory info = IVaultPortal(VAULT_PORTAL).getVault(taxToken);
        require(info.vault != address(0), "no vault created");

        string memory json = "flap";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "deployer", me);
        vm.serializeAddress(json, "identityRegistry", IDENTITY_REGISTRY_56);
        vm.serializeAddress(json, "token", address(token));
        vm.serializeAddress(json, "vault", address(custody));
        vm.serializeAddress(json, "roster", address(roster));
        vm.serializeAddress(json, "tournament", address(tournament));
        vm.serializeAddress(json, "flapFactory", address(factory));
        vm.serializeAddress(json, "taxToken", taxToken);
        string memory out = vm.serializeAddress(json, "flapVault", info.vault);
        vm.writeJson(out, "deployments/flap-demo.json");

        console2.log("tax token   ", taxToken);
        console2.log("flap vault  ", info.vault);
        console2.log("factory     ", address(factory));
        console2.log("tournament  ", address(tournament));
        console2.log("vaultType   ", AssayFlapVault(payable(info.vault)).vaultUISchema().vaultType);
    }
}
