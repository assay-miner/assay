// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "../src/flap/IPortal.sol";
import {AssayFlapFactory} from "../src/AssayFlapFactory.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {Tournament} from "../src/Tournament.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {TaxTokenMock} from "./TaxTokenMock.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";
import {ClonesUpgradeable} from "@openzeppelin-contracts-upgradeable/proxy/ClonesUpgradeable.sol";

/// @notice Answers one question with the real contract rather than with its documentation:
///         can anybody launch a token against their own vault factory, or does Flap have to
///         register that factory first?
///
/// @dev The interface comment for the schema types says "any contract that implements
///      VaultFactoryBaseV2 can be used to launch tokens via VaultPortal — no on-chain
///      registration is required", while the same repository defines
///      `error VaultFactoryNotRegistered(address)` and gates `registerVaultFactory` behind
///      VAULT_ADMIN_ROLE. Both cannot be true. This forks mainnet and finds out which is.
contract FlapGateTest is Test {
    address payable internal constant VAULT_PORTAL =
        payable(0x90497450f2a706f1951b5bdda52B4E5d16f34C06);
    /// A factory Flap has registered, for the control arm.
    address internal constant FLAP_X_VAULT_FACTORY = 0x025549F52B03cF36f9e1a337c02d3AA7Af66ab32;
    /// Something that is definitely not registered.
    address internal constant UNREGISTERED = 0x000000000000000000000000000000000000dEaD;
    /// The Portal is what clones the token, so it is the CREATE2 deployer the salt must satisfy.
    address internal constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    /// Flap's taxed-V3 token implementation — the same one PetalFi's token is a clone of.
    address internal constant TOKEN_IMPL_TAXED_V3 = 0x024f18294970B5c76c0691b87f138A0317156422;

    /// @dev A taxed-V3 launch must land on an address ending 0x7777, so the salt has to be mined
    ///      rather than chosen. Pure arithmetic — no RPC in the loop.
    ///
    ///      Mining from a low offset finds the salts everybody else found first: the first 0x7777
    ///      address for this implementation was staged on mainnet long ago, and the portal refuses
    ///      it with TokenAlreadyStaged. So the search starts somewhere nobody has swept.
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

    bool internal forked;

    function setUp() public {
        try vm.createSelectFork(vm.rpcUrl("bsc")) {
            forked = true;
        } catch {
            forked = false;
        }
    }

    function _params(address factory, bytes32 salt)
        internal
        pure
        returns (IVaultPortalTypes.NewTokenV6WithVaultParams memory p)
    {
        // FOUR_FIFTHS is the only threshold this portal accepts for a taxed-V3 launch. Probed
        // against mainnet by trying all six: the other five revert InvalidDexThresholdType, and
        // this one gets past that check. The interface documents the enum but not which member a
        // V3 launch permits, and a wrong one reverts with a name that does not say which is right.
        return _params(factory, salt, IPortalCommonTypes.DexThreshType.FOUR_FIFTHS);
    }

    function _params(
        address factory,
        bytes32 salt,
        IPortalCommonTypes.DexThreshType thresh
    ) internal pure returns (IVaultPortalTypes.NewTokenV6WithVaultParams memory p) {
        p.name = "Assay";
        p.symbol = "ASSAY";
        p.meta = "";
        p.dexThresh = thresh;
        p.salt = salt;
        p.migratorType = IPortalTypes.MigratorType.V2_MIGRATOR;
        p.quoteToken = address(0);
        p.quoteAmt = 0;
        p.dexId = IPortalTypes.DEXId.DEX0;
        p.buyTaxRate = 200;
        p.sellTaxRate = 200;
        p.taxDuration = 365 days;
        p.antiFarmerDuration = 30 days;
        p.mktBps = 10_000;
        p.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        p.vaultFactory = factory;
        p.vaultData = "";
    }

    /// @dev A factory address with no code fails because there is nothing there to call — NOT
    ///      because the portal checked a registry. Worth pinning: the difference between those
    ///      two is the difference between "we need Flap's permission" and "we do not".
    function test_AnEmptyAddressFailsForLackOfCodeNotRegistration() public {
        if (!forked) {
            emit log("SKIPPED: bsc mainnet RPC unreachable");
            return;
        }
        address launcher = makeAddr("launcher");
        vm.deal(launcher, 10 ether);
        vm.prank(launcher);
        try IVaultPortal(VAULT_PORTAL).newTokenV6WithVault{value: 0}(_params(UNREGISTERED, bytes32(uint256(1)))) {
            revert("an address with no code cannot have created a vault");
        } catch (bytes memory reason) {
            bytes4 sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            assertTrue(
                sel != IVaultPortalTypes.VaultFactoryNotRegistered.selector,
                "the portal did not reject this on registration grounds"
            );
        }
    }

    /// @dev The result that decides the roadmap: OUR factory, which Flap has never registered and
    ///      never heard of, launches a real token with a real vault through their real portal on
    ///      a mainnet fork. Registration turns out to be an endorsement (official / risk level),
    ///      not a permission — so this can ship now and be endorsed later.
    function test_OurUnregisteredFactoryCanLaunchOnMainnet() public {
        if (!forked) {
            emit log("SKIPPED: bsc mainnet RPC unreachable");
            return;
        }

        address launcher = makeAddr("launcher");
        vm.deal(launcher, 100 ether);

        // Stand the ASSAY stack up on the fork, then a factory pointing at it.
        vm.startPrank(launcher);
        TaxTokenMock token = new TaxTokenMock(launcher, 1_000_000_000e18);
        AssayVault custody = new AssayVault(IERC20(address(token)), launcher);
        AgentRoster roster = new AgentRoster(
            IIdentityRegistry(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432), custody, 1000e18, launcher
        );
        Tournament tournament = new Tournament(custody, roster, launcher);
        custody.addController(address(roster));
        custody.addController(address(tournament));
        custody.freeze();
        roster.setConsumer(address(tournament));
        AssayFlapFactory factory = new AssayFlapFactory(tournament);
        vm.stopPrank();

        // Confirm Flap has never registered it.
        (bool enabled,,,) = IVaultPortal(VAULT_PORTAL).vaultFactories(address(factory));
        assertFalse(enabled, "our factory is not registered with Flap");

        bytes32 salt = _mineVanitySalt(uint256(keccak256("assay.vanity.v1")));
        emit log_named_bytes32("salt", salt);
        emit log_named_address(
            "predicted token",
            ClonesUpgradeable.predictDeterministicAddress(TOKEN_IMPL_TAXED_V3, salt, PORTAL)
        );

        vm.prank(launcher);
        address taxToken =
            IVaultPortal(VAULT_PORTAL).newTokenV6WithVault{value: 0}(_params(address(factory), salt));

        emit log_named_address("tax token", taxToken);
        assertTrue(taxToken != address(0), "a token was created");

        // And the portal now knows the vault, which is what a UI looks up.
        IVaultPortalTypes.VaultInfo memory info = IVaultPortal(VAULT_PORTAL).getVault(taxToken);
        emit log_named_address("vault", info.vault);
        assertTrue(info.vault != address(0), "a vault was created for it");
        assertEq(AssayFlapVault(payable(info.vault)).taxToken(), taxToken, "vault knows its token");

        // The thing Flap's page actually renders from.
        VaultUISchema memory schema = AssayFlapVault(payable(info.vault)).vaultUISchema();
        emit log_named_string("vaultType", schema.vaultType);
        assertEq(schema.vaultType, "AssayVault");
        assertGt(schema.methods.length, 0, "the schema has methods to render");
        emit log_named_string("description()", AssayFlapVault(payable(info.vault)).description());
    }

    /// @dev The control. A factory Flap HAS registered gets past that check — it fails later, on
    ///      something else, which is what proves the gate above is specifically about registration
    ///      and not about the rest of these parameters being wrong.
    function test_RegisteredFactoryGetsPastTheGate() public {
        if (!forked) {
            emit log("SKIPPED: bsc mainnet RPC unreachable");
            return;
        }

        address launcher = makeAddr("launcher");
        vm.deal(launcher, 10 ether);
        vm.prank(launcher);
        try IVaultPortal(VAULT_PORTAL).newTokenV6WithVault{value: 0}(
            _params(FLAP_X_VAULT_FACTORY, bytes32(uint256(1)))
        ) returns (address token) {
            emit log_named_address("launched", token);
        } catch (bytes memory reason) {
            bytes4 sel;
            if (reason.length >= 4) {
                sel = bytes4(reason);
            }
            emit log_named_bytes32("revert selector", bytes32(sel));
            assertTrue(
                sel != IVaultPortalTypes.VaultFactoryNotRegistered.selector,
                "a registered factory must not fail the registration check"
            );
        }
    }

    /// @dev And the registration state itself, read straight off the portal.
    function test_RegistrationStateOnMainnet() public {
        if (!forked) {
            emit log("SKIPPED: bsc mainnet RPC unreachable");
            return;
        }
        (bool oursEnabled,,,) = IVaultPortal(VAULT_PORTAL).vaultFactories(UNREGISTERED);
        (bool theirsEnabled, bool theirsOfficial,,) =
            IVaultPortal(VAULT_PORTAL).vaultFactories(FLAP_X_VAULT_FACTORY);

        assertFalse(oursEnabled, "an address nobody registered is not enabled");
        assertTrue(theirsEnabled, "Flap's own factory is enabled");
        assertTrue(theirsOfficial, "and marked official");
    }
}
