// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {TaxTokenMock} from "./TaxTokenMock.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {Tournament} from "../src/Tournament.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {AssayFlapFactory} from "../src/AssayFlapFactory.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
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
///      The contract to watch is whichever one carries the vault's creation code, because that is
///      what grows when the vault does, and the vault is where features get added. That used to be
///      the factory, which left it 345 bytes of headroom. `AssayVaultDeployer` holds it now — the
///      factory builds one in its constructor, so the code lands in the factory's *creation* code,
///      which EIP-170 does not measure, instead of its runtime, which it does. The factory dropped
///      from 24,231 bytes to 2,637 and the binding constraint moved to the deployer.
contract CodeSizeTest is Test {
    /// @dev This fixture never posts on the drawn lane, so the generator is a placeholder.
    ///      Naming it says that on purpose rather than leaving a bare address to be read as real.
    address internal constant NO_DRAWN_LANE = address(0xDEAD);

    uint256 internal constant EIP170 = 24_576;
    /// @dev A build this close to the ceiling is one feature away from being undeployable, and
    ///      that failure lands during a broadcast. Fail here instead, while it is free.
    ///
    ///      This was a kilobyte until the second audit round. Three mandatory correctness fixes
    ///      cost the vault 752 bytes, and the vault is at a ceiling that is not ours to raise:
    ///      `vaultUISchema()` alone is about seven kilobytes and cannot leave the vault, because
    ///      `VaultBaseV2` declares it `public pure virtual` and a `pure` override cannot call an
    ///      external contract. Three things were measured before this number moved — moving the
    ///      gates into Tournament cost 67 bytes MORE than inlining them, narrowing the task tuple
    ///      reads saved 13, and tightening the schema's own labels saved 167. What remains is real
    ///      margin, not slack.
    ///
    ///      That structural change has now happened, and it is why this is back to a kilobyte: the
    ///      vault's creation code moved out of the factory into `AssayVaultDeployer`, taking the
    ///      headroom on the binding contract from 345 bytes to 2,274. `vaultUISchema()` is still
    ///      about seven kilobytes and still cannot leave the vault — `VaultBaseV2` declares it
    ///      `public pure virtual` and a `pure` override cannot call out — so the deployer is the
    ///      number to watch from here.
    uint256 internal constant HEADROOM = 1024;

    Tournament internal tournament;

    function setUp() public {
        // Chain 56 so the vault's constructor resolves a venue; this is a size check, so the
        // fork only has to exist, not to be at any particular block.
        vm.createSelectFork(vm.rpcUrl("bsc"));
        TaxTokenMock token = new TaxTokenMock(address(this), 1_000_000_000e18);
        AssayVault custody = new AssayVault(IERC20(address(token)), address(this));
        AgentRoster roster =
            new AgentRoster(IIdentityRegistry(address(0)), custody, 1000e18);
        tournament = new Tournament(custody, roster, address(this), NO_DRAWN_LANE);
    }

    function test_TheFactoryFitsWithRoomToSpare() public {
        AssayFlapFactory factory = new AssayFlapFactory(tournament, new PriceGuard());
        uint256 size = address(factory).code.length;
        console2.log("factory runtime      ", size);
        console2.log("headroom to EIP-170  ", EIP170 - size);
        assertLt(size, EIP170, "factory exceeds EIP-170 and cannot be deployed at all");
        assertLt(size, EIP170 - HEADROOM, "factory is within a kilobyte of the ceiling");
    }

    /// @dev The one that actually binds. It carries the vault's creation code, so it is the
    ///      contract that grows when the vault does — and a vault too big to deploy through would
    ///      make every launch fail at the portal rather than here, where it is free.
    function test_TheDeployerFitsWithRoomToSpare() public {
        AssayFlapFactory factory = new AssayFlapFactory(tournament, new PriceGuard());
        uint256 size = address(factory.deployer()).code.length;
        console2.log("deployer runtime     ", size);
        console2.log("headroom to EIP-170  ", EIP170 - size);
        assertLt(size, EIP170, "deployer exceeds EIP-170: no vault could be created at all");
        assertLt(
            size,
            EIP170 - HEADROOM,
            "deployer is within a kilobyte of the ceiling: the next vault feature will not deploy"
        );
    }

    function test_TheVaultFits() public {
        uint256 size =
            address(new AssayFlapVault(tournament, address(1), address(2), new PriceGuard())).code.length;
        console2.log("vault runtime        ", size);
        assertLt(size, EIP170, "vault exceeds EIP-170");
    }

    function test_TheTournamentFits() public view {
        console2.log("tournament runtime   ", address(tournament).code.length);
        assertLt(address(tournament).code.length, EIP170, "tournament exceeds EIP-170");
    }
}
