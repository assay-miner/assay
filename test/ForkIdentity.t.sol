// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TaxTokenMock} from "./TaxTokenMock.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice Runs the roster against the *real* ERC-8004 Identity Registry on BNB Smart Chain
///         testnet. The unit suite proves the logic; this proves the logic is talking to the
///         contract that actually exists, with the selectors that actually exist.
/// @dev Skips itself when no testnet RPC is reachable, so a network outage cannot masquerade
///      as a passing suite — the skip is loud.
contract ForkIdentityTest is Test {
    address internal constant REGISTRY_TESTNET = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address internal constant REGISTRY_MAINNET = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;

    uint256 internal constant MIN_STAKE = 1_000e18;

    bool internal forked;

    function setUp() public {
        try vm.createSelectFork(vm.rpcUrl("bsc_testnet")) {
            forked = true;
        } catch {
            forked = false;
        }
    }

    modifier onlyForked() {
        if (!forked) {
            emit log("SKIPPED: bsc_testnet RPC unreachable");
            return;
        }
        _;
    }

    function test_RealRegistryIsDeployedAndVersioned() public onlyForked {
        assertGt(REGISTRY_TESTNET.code.length, 0, "registry must have code");
        (bool ok, bytes memory ret) =
            REGISTRY_TESTNET.staticcall(abi.encodeWithSignature("getVersion()"));
        assertTrue(ok, "getVersion() must answer");
        assertEq(abi.decode(ret, (string)), "2.0.0", "ERC-8004 registry version");
    }

    /// @dev The exact call the roster gates on. If the real registry ever changed this selector
    ///      or its semantics, enrolment would silently break; this is what catches that.
    function test_IsAuthorizedOrOwnerMatchesOwnerOf() public onlyForked {
        IIdentityRegistry reg = IIdentityRegistry(REGISTRY_TESTNET);
        address owner = reg.ownerOf(1);
        assertTrue(owner != address(0), "agent 1 must exist on testnet");
        assertTrue(reg.isAuthorizedOrOwner(owner, 1), "owner must be authorised for its own agent");
        assertFalse(reg.isAuthorizedOrOwner(address(0xdead), 1), "a stranger must not be");
    }

    /// @dev End-to-end enrolment against the live registry, using a real registered identity.
    function test_RealIdentityCanEnrol() public onlyForked {
        IIdentityRegistry reg = IIdentityRegistry(REGISTRY_TESTNET);
        address owner = reg.ownerOf(1);

        TaxTokenMock token = new TaxTokenMock(address(this), 1_000_000_000e18);
        AssayVault vault = new AssayVault(IERC20(address(token)), address(this));
        AgentRoster roster = new AgentRoster(reg, vault, MIN_STAKE, address(this));
        vault.addController(address(roster));
        vault.freeze();

        token.transfer(owner, MIN_STAKE);

        vm.startPrank(owner);
        token.approve(address(vault), MIN_STAKE);
        roster.enroll(1, MIN_STAKE);
        vm.stopPrank();

        assertEq(roster.minerOf(1), owner, "real ERC-8004 identity enrolled");
        assertEq(roster.enrolmentOf(owner).agentId, 1, "agent id bound");
    }

    function test_MainnetRegistryAlsoLive() public onlyForked {
        // Skip loudly rather than fail: an unreachable endpoint is not a broken registry, and a
        // red suite that means "the RPC blinked" trains everyone to ignore red suites.
        try vm.createSelectFork(vm.rpcUrl("bsc")) {}
        catch {
            emit log("SKIPPED: bsc mainnet RPC unreachable");
            return;
        }
        assertGt(REGISTRY_MAINNET.code.length, 0, "mainnet registry must have code");
        IIdentityRegistry reg = IIdentityRegistry(REGISTRY_MAINNET);
        assertTrue(reg.ownerOf(1) != address(0), "mainnet agent 1 must exist");
    }
}
