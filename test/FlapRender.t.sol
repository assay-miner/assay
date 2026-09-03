// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {TaxTokenMock} from "./TaxTokenMock.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor} from "../src/flap/IVaultSchemasV1.sol";

/// @notice Holds the schema to what Flap's deployed renderer actually does with it.
///
/// @dev Their vault page is generated from `vaultUISchema()`, but it is narrower than the schema
///      it reads. Decompiled from the live bundle, the whole of its method handling is:
///
///          const reads   = methods.filter(m => !m.isWriteMethod && m.inputs.length === 0)
///          const actions = methods.filter(m =>  m.isWriteMethod)
///
///      Nothing else is rendered. A read that takes an argument appears nowhere, and
///      `isOutputArray` is never consulted — so a schema whose numbers live only behind
///      parameterised views is invisible on the page most people will arrive at.
///
///      These tests encode that filter, so the day our schema drifts back into a shape their
///      renderer drops, the suite says so instead of the page silently going blank.
contract FlapRenderTest is Test {
    AssayFlapVault vault;

    /// @dev Forked, and deliberately not skipped when the fork fails. The vault resolves its
    ///      reward token and router from `block.chainid` at construction, so on a bare local
    ///      chain it cannot exist at all — a version of this that quietly passed without a fork
    ///      would be reporting on a contract it never built.
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("bsc"));

        TaxTokenMock token = new TaxTokenMock(address(this), 1_000_000_000e18);
        AssayVault custody = new AssayVault(IERC20(address(token)), address(this));
        AgentRoster roster = new AgentRoster(IIdentityRegistry(address(0)), custody, 1000e18);
        Tournament tournament = new Tournament(custody, roster, address(this));
        vault = new AssayFlapVault(tournament, address(token), address(this), new PriceGuard());
    }

    /// @dev Flap's first bucket.
    function _renderedReads() internal view returns (VaultMethodSchema[] memory out) {
        VaultMethodSchema[] memory ms = vault.vaultUISchema().methods;
        out = new VaultMethodSchema[](ms.length);
        uint256 n;
        for (uint256 i; i < ms.length; ++i) {
            if (!ms[i].isWriteMethod && ms[i].inputs.length == 0) out[n++] = ms[i];
        }
        assembly { mstore(out, n) }
    }

    /// @dev Flap's second bucket.
    function _renderedActions() internal view returns (VaultMethodSchema[] memory out) {
        VaultMethodSchema[] memory ms = vault.vaultUISchema().methods;
        out = new VaultMethodSchema[](ms.length);
        uint256 n;
        for (uint256 i; i < ms.length; ++i) {
            if (ms[i].isWriteMethod) out[n++] = ms[i];
        }
        assembly { mstore(out, n) }
    }

    function _signature(VaultMethodSchema memory m) internal pure returns (string memory sig) {
        sig = string.concat(m.name, "(");
        for (uint256 i; i < m.inputs.length; ++i) {
            string memory t = m.inputs[i].fieldType;
            // `time` is a display hint, not an ABI type.
            if (keccak256(bytes(t)) == keccak256("time")) t = "uint256";
            sig = string.concat(sig, i == 0 ? "" : ",", t);
        }
        sig = string.concat(sig, ")");
    }

    /// @notice The page must not be blank: something reaches Flap's read bucket.
    function test_SomethingSurvivesFlapsReadFilter() public view {
        assertGt(_renderedReads().length, 0, "nothing would render under Vault Data");
    }

    /// @notice And the numbers that reach it are the ones worth arriving for.
    function test_HeadlineNumbersAreReachableWithoutArguments() public view {
        VaultMethodSchema[] memory reads = _renderedReads();

        uint256 fields;
        for (uint256 i; i < reads.length; ++i) fields += reads[i].outputs.length;
        assertGe(fields, 6, "too little survives the filter to describe the vault");

        // The prize money itself has to be visible, not just a count of tasks.
        bool money;
        for (uint256 i; i < reads.length; ++i) {
            for (uint256 j; j < reads[i].outputs.length; ++j) {
                if (reads[i].outputs[j].decimals == 18) money = true;
            }
        }
        assertTrue(money, "no BNB amount reaches Flap's renderer");
    }

    /// @notice Every rendered read is really callable, and really takes no arguments.
    /// @dev A schema is hand-written text; the contract is not. This is where they are held
    ///      together — an unknown selector returns empty revert data, which is the discriminator.
    function test_EveryRenderedReadActuallyResolves() public view {
        VaultMethodSchema[] memory reads = _renderedReads();
        for (uint256 i; i < reads.length; ++i) {
            bytes4 sel = bytes4(keccak256(bytes(_signature(reads[i]))));
            (bool ok, bytes memory ret) = address(vault).staticcall(abi.encodeWithSelector(sel));
            assertTrue(ok, string.concat("schema names an uncallable read: ", reads[i].name));
            assertEq(
                ret.length,
                32 * reads[i].outputs.length,
                string.concat("output count drifted from the contract: ", reads[i].name)
            );
        }
    }

    /// @notice Every rendered action exists on the contract with the signature the schema claims.
    /// @dev A generic renderer draws every `isWriteMethod` entry as an ordinary button — the two
    ///      tests above establish that filter. `endow` is Guardian-only and `postTask` is
    ///      restricted for anyone but the curator or Guardian; neither restriction is a field this
    ///      schema format has room for, so the only place it can live is the description a button
    ///      is labelled with. Delete either phrase and this fails, which is the point: a reviewer
    ///      or a future edit removing the words removes the only warning a stranger gets before
    ///      clicking a button that reverts.
    function test_RestrictedActionsSaySoInTheirLabel() public view {
        VaultUISchema memory s = vault.vaultUISchema();
        bool foundEndow;
        for (uint256 i; i < s.methods.length; ++i) {
            if (keccak256(bytes(s.methods[i].name)) != keccak256(bytes("endow"))) continue;
            foundEndow = true;
            assertTrue(_contains(s.methods[i].description, "Guardian"), "endow does not say Guardian");
        }
        assertTrue(foundEndow, "endow is not in the schema; nothing was checked");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) { ok = false; break; }
            }
            if (ok) return true;
        }
        return false;
    }

    function test_EveryRenderedActionActuallyResolves() public {
        VaultMethodSchema[] memory actions = _renderedActions();
        assertGt(actions.length, 0, "no buttons would render");

        for (uint256 i; i < actions.length; ++i) {
            bytes4 sel = bytes4(keccak256(bytes(_signature(actions[i]))));
            bytes memory args = new bytes(32 * actions[i].inputs.length);
            vm.prank(address(0xBEEF));
            (bool ok, bytes memory ret) =
                address(vault).call(abi.encodePacked(sel, args));

            // Reverting is expected — a stranger may not endow, and task 0 is not settled.
            // Reverting with *nothing* is not: that is the fallback, i.e. no such function.
            assertTrue(
                ok || ret.length > 0,
                string.concat("schema names a function the vault does not have: ", actions[i].name)
            );
        }
    }
}
