// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";

/// @notice The launch guard has to identify the ERC-8004 registry by what it *answers*, not by
///         whether it has code. On BNB Smart Chain mainnet the testnet registry address is also
///         occupied — by a different, incompatible deployment — so a has-code check would wave a
///         mis-pasted address straight through.
contract LaunchGuardTest is Test {
    Deploy internal deploy;

    /// The address that is the registry on testnet. It is NOT the registry on mainnet.
    address internal constant TESTNET_REGISTRY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address internal constant MAINNET_REGISTRY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;

    function setUp() public {
        deploy = new Deploy();
    }

    function test_ChainIdMapsToTheRightRegistry() public view {
        assertEq(deploy.registryFor(56), MAINNET_REGISTRY);
        assertEq(deploy.registryFor(97), TESTNET_REGISTRY);
    }

    function test_UnsupportedChainReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, uint256(1)));
        deploy.registryFor(1);
    }

    function test_CanonicalRegistryPasses() public {
        MockIdentityRegistry ok = new MockIdentityRegistry();
        deploy.assertCanonicalRegistry(address(ok));
    }

    /// @dev Break what the guard guards: a contract that exists, has code, and answers a
    ///      different version. This is the exact shape of the mainnet mis-paste.
    function test_WrongVersionRegistryIsRejected() public {
        MockIdentityRegistry wrong = new MockIdentityRegistry();
        wrong.setIdentity("AgentIdentity", "0.0.1");
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.WrongRegistry.selector, address(wrong), "AgentIdentity", "0.0.1"
            )
        );
        deploy.assertCanonicalRegistry(address(wrong));
    }

    function test_RegistryThatRevertsOnNameIsRejected() public {
        MockIdentityRegistry wrong = new MockIdentityRegistry();
        wrong.setIdentity("", "2.0.0");
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.WrongRegistry.selector, address(wrong), "", "2.0.0")
        );
        deploy.assertCanonicalRegistry(address(wrong));
    }

    /// @dev The real thing, on the real chain: point the guard at the genuine mis-paste target
    ///      and watch it refuse. This is the test that would have caught a bad launch.
    function test_Fork_RealMainnetMisPasteIsRejected() public {
        try vm.createSelectFork(vm.rpcUrl("bsc")) {
            deploy = new Deploy();
            // Sanity: the wrong address really is occupied on mainnet, so "has code" is useless.
            assertGt(TESTNET_REGISTRY.code.length, 0, "mis-paste target must have code on mainnet");

            vm.expectRevert();
            deploy.assertCanonicalRegistry(TESTNET_REGISTRY);

            // And the right one passes on the same chain.
            deploy.assertCanonicalRegistry(MAINNET_REGISTRY);
        } catch {
            emit log("SKIPPED: bsc mainnet RPC unreachable");
        }
    }
}
