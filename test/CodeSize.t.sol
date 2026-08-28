// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {AssayToken} from "../src/AssayToken.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {AssayFlapFactory} from "../src/AssayFlapFactory.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";

/// @notice Refuses a build that cannot be deployed.
///
/// @dev EIP-170 caps deployed code at 24,576 bytes. A contract over it compiles, tests and passes
///      every other gate — then fails at the one moment that costs something. That happened here:
///      a price-impact check pushed the factory to 25,398, and it was the broadcast that said so,
///      after the tournament beside it had already landed and been paid for.
///
///      Sizes are measured by deploying, not by reading `runtimeCode`, which Solidity refuses for
///      any contract with immutables — which is all of these. Deploying is what the chain does
///      anyway, so it is the honest measurement.
///
///      The factory is the one to watch, and not for its own logic: roughly 2,300 bytes of it is
///      the factory and the rest is the vault's creation code, carried in full. The factory
///      therefore grows whenever the vault grows, and the vault is where features get added.
contract CodeSizeTest is Test {
    uint256 internal constant EIP170 = 24_576;
    /// @dev A build this close to the ceiling is one feature away from being undeployable, and
    ///      that failure lands during a broadcast. Fail here instead, while it is free.
    uint256 internal constant HEADROOM = 1_024;

    Tournament internal tournament;

    function setUp() public {
        // Chain 56 so the vault's constructor resolves a venue; this is a size check, so the
        // fork only has to exist, not to be at any particular block.
        vm.createSelectFork(vm.rpcUrl("bsc"));
        AssayToken token = new AssayToken(address(this));
        AssayVault custody = new AssayVault(IERC20(address(token)), address(this));
        AgentRoster roster =
            new AgentRoster(IIdentityRegistry(address(0)), custody, 1000e18, address(this));
        tournament = new Tournament(custody, roster, address(this));
    }

    function test_TheFactoryFitsWithRoomToSpare() public {
        uint256 size = address(new AssayFlapFactory(tournament)).code.length;
        console2.log("factory runtime      ", size);
        console2.log("headroom to EIP-170  ", EIP170 - size);
        assertLt(size, EIP170, "factory exceeds EIP-170 and cannot be deployed at all");
        assertLt(
            size,
            EIP170 - HEADROOM,
            "factory is within a kilobyte of the ceiling: the next feature will not deploy"
        );
    }

    function test_TheVaultFits() public {
        uint256 size =
            address(new AssayFlapVault(tournament, address(1), address(2))).code.length;
        console2.log("vault runtime        ", size);
        assertLt(size, EIP170, "vault exceeds EIP-170");
    }

    function test_TheTournamentFits() public view {
        console2.log("tournament runtime   ", address(tournament).code.length);
        assertLt(address(tournament).code.length, EIP170, "tournament exceeds EIP-170");
    }
}
