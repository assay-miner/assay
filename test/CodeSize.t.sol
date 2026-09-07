// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";

import {Stack} from "../script/Stack.sol";
import {TaxTokenMock} from "./TaxTokenMock.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";

/// @notice Refuses a build that cannot be deployed.
///
/// @dev EIP-170 caps deployed code at 24,576 bytes. A contract over it compiles, tests and passes
///      every other gate — then fails at the one moment that costs something. That happened here:
///      a price-impact check pushed the factory to 25,398, and it was the broadcast that said so,
///      after the tournament beside it had already landed and been paid for.
///
///      Sizes are measured by deploying rather than by reading `type(C).runtimeCode`. That started
///      as a compiler restriction — `runtimeCode` is refused for any contract with immutables, and
///      every contract here had them — and the beacon conversion turned those immutables into
///      storage, so the restriction is gone. The measurement stays, for a better reason: the
///      addresses below are the ones `Stack.deploy` produced, and `Stack.deploy` is what the
///      broadcast runs, so what is measured is what a deployment actually puts on chain.
///
///      What this file used to be about, and why it no longer is. `newVault` constructed the vault
///      directly, and constructing a contract puts that contract's whole creation code into the
///      RUNTIME of the one writing it — which is exactly what EIP-170 measures. The factory sat at
///      24,231 bytes with 345 to spare, and every byte added to the vault came off that margin.
///      `AssayVaultDeployer` was invented to move that creation code somewhere the limit does not
///      look: the factory built one in its constructor, so the vault's code landed in the factory's
///      *creation* code instead of its runtime, the factory fell to 2,637 bytes, and the binding
///      constraint moved to the deployer.
///
///      Putting every contract behind an `UpgradeableBeacon` deletes that problem rather than
///      relocating it. `newVault` creates a `BeaconProxy` now — 1,146 bytes of creation code
///      against the vault's 22,121 — so the factory never carries a vault at all, and the contract
///      invented to hold what it used to carry is deleted with the pressure that created it.
///      `test_TheFactoryDoesNotCarryTheVaultsCreationCode` asserts that property directly, because
///      it is the one thing `AssayVaultDeployer` existed to produce and the only thing whose loss
///      would bring it back.
///
///      With no contract embedding another, each implementation stands alone against the ceiling.
///      That is seven measurements now rather than the one or two that mattered when the factory
///      was carrying the vault.
contract CodeSizeTest is Test {
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
    ///      It is a kilobyte again, and it now applies to all seven implementations rather than to
    ///      whichever one was carrying the vault's creation code. The contract to watch changed
    ///      with it: freed of the factory, the vault has 2,651 bytes to spare, and the tightest of
    ///      the seven is now `Tournament` at 23,100 bytes — 1,476 to spare, which clears this bar
    ///      by 452. The table below prints which one is tightest on every run rather than leaving
    ///      that here to go stale.
    uint256 internal constant HEADROOM = 1024;

    Stack.Deployed internal stack;

    /// @dev A launched vault, in the shape the factory produces one: a `BeaconProxy`. Built in
    ///      `setUp` rather than inside the gas test so the beacon and the implementation behind it
    ///      are cold when the transfer lands, which is what they are for the first tax payment
    ///      into a freshly launched vault.
    AssayFlapVault internal launchedVault;

    function setUp() public {
        // Chain 56 so `PriceGuard.initialize` and the flap vault resolve a venue and can read
        // `WETH()` off the real router; this is a size check, so the fork only has to exist, not
        // to be at any particular block.
        vm.createSelectFork(vm.rpcUrl("bsc"));
        TaxTokenMock token = new TaxTokenMock(address(this), 1_000_000_000e18);
        // `Stack.guardian()` rather than a written-out address: the Guardian owns the seven beacons
        // and affects nobody's code size, but a second hardcoded copy of it is a second place for
        // the fact to be wrong. Fixtures that run on the local chain reach for `Guardians` instead,
        // because the derivation returns zero there; this one forks a chain Flap is actually on, so
        // the derived answer is the real one.
        stack = Stack.deploy(
            Stack.Params({
                deployer: address(this),
                guardian: Stack.guardian(),
                asset: address(token),
                salvage: address(this),
                registry: address(0),
                minStake: 1000e18,
                curator: address(this)
            })
        );
        // The factory's own vault beacon, reached through the library rather than by hand, with a
        // placeholder tax token and curator: `receive()` reads neither, so nothing here has to be
        // the fixture's own token.
        launchedVault = Stack.newFlapVault(
            Stack.guardian(), stack.tournament, address(1), address(2), stack.priceGuard
        );
    }

    /// @dev The whole ceiling check, in one table. Behind beacons there is no single contract to
    ///      single out: every implementation is deployed on its own and measured on its own, so a
    ///      regression in any one of the seven is a broadcast that fails.
    function test_EveryImplementationFitsWithRoomToSpare() public view {
        string[7] memory names = [
            string("PriceGuard      "),
            "AssayVault      ",
            "AgentRoster     ",
            "Tournament      ",
            "TaskGenerator   ",
            "AssayFlapVault  ",
            "AssayFlapFactory"
        ];
        address[7] memory impls = [
            stack.impls.priceGuard,
            stack.impls.vault,
            stack.impls.roster,
            stack.impls.tournament,
            stack.impls.generator,
            stack.impls.flapVault,
            stack.impls.factory
        ];

        uint256 tightest = type(uint256).max;
        string memory binding;
        for (uint256 i; i < names.length; ++i) {
            uint256 headroom = _fits(names[i], impls[i]);
            if (headroom < tightest) {
                tightest = headroom;
                binding = names[i];
            }
        }
        // Which contract the next feature will break, printed rather than remembered.
        console2.log("tightest             ", binding, tightest);
    }

    /// @dev The property `AssayVaultDeployer` was invented to produce, asserted instead of
    ///      described. Two statements of it: the factory's runtime does not contain the vault's
    ///      creation code anywhere, and the factory is smaller than that creation code — the
    ///      second is the structural half, since no code can contain something longer than itself,
    ///      and it holds however the search is written.
    ///
    ///      The positive half matters as much. What `newVault` embeds now is a `BeaconProxy`, and
    ///      only a search for that creation code says so: putting the vault back would trip the
    ///      first two assertions, but embedding anything else — another deployer contract, a
    ///      clone, a second factory — would trip only this one.
    function test_TheFactoryDoesNotCarryTheVaultsCreationCode() public view {
        bytes memory vaultCreation = type(AssayFlapVault).creationCode;
        bytes memory proxyCreation = type(BeaconProxy).creationCode;
        bytes memory factoryRuntime = stack.impls.factory.code;

        console2.log("factory runtime      ", factoryRuntime.length);
        console2.log("vault creation code  ", vaultCreation.length);
        console2.log("proxy creation code  ", proxyCreation.length);
        console2.log("launched vault code  ", address(launchedVault).code.length);

        assertFalse(
            _contains(factoryRuntime, vaultCreation),
            "the factory carries the vault's creation code again"
        );
        assertLt(
            factoryRuntime.length,
            vaultCreation.length,
            "the factory is big enough to be carrying a vault; it should only carry a proxy"
        );
        assertTrue(
            _contains(factoryRuntime, proxyCreation),
            "the factory does not create a BeaconProxy: newVault builds something else now"
        );
    }

    /// @dev `receive()` gas, measured rather than restated.
    ///
    ///      SUBMISSION.md carried "**12,988** — 1.3% of the 1,000,000 ceiling" under a heading that
    ///      reads "Measured, not estimated". Nothing measured it: grep for the figure found it in
    ///      that one document and nowhere else. A number written once and then quoted is the same
    ///      defect as a comment that stopped being true — it just looks more like evidence.
    ///
    ///      Rule 005 caps what a vault may spend in `receive()`, so this is worth having as a real
    ///      measurement. The document cites this test now instead of repeating its result.
    function test_ReceiveStaysUnderTheGasCeiling() public {
        // Measured through the proxy, because a proxy is what the tax arrives at: every vault the
        // factory creates is a `BeaconProxy`, and the beacon read and the delegatecall into the
        // implementation are part of what `receive()` costs now. Measuring a bare implementation
        // would report a number no launched vault ever pays.
        // Read out of storage before the window opens: a cold SLOAD for `launchedVault` is this
        // test's cost, not `receive()`'s, and counting it would overstate what the vault spends.
        AssayFlapVault flap = launchedVault;
        vm.deal(address(this), 1 ether);

        uint256 before = gasleft();
        (bool ok,) = payable(address(flap)).call{value: 0.01 ether}("");
        uint256 used = before - gasleft();
        assertTrue(ok, "receive reverted");

        console2.log("receive() gas        ", used);
        assertLt(used, 1_000_000, "receive() exceeds the Rule 005 ceiling");

        // A ceiling test that only checks the ceiling would pass if receive() started making
        // external calls and cost fifty times as much. This is the shape it actually has: an event
        // and nothing else, plus the proxy hop in front of it.
        assertLt(used, 50_000, "receive() got much more expensive; it should only emit");
    }

    /// @dev One implementation against the ceiling, logged with its measured headroom.
    function _fits(string memory name, address impl) internal view returns (uint256 headroom) {
        uint256 size = impl.code.length;
        assertGt(size, 0, string.concat(name, ": no code at the address Stack.deploy returned"));
        assertLt(
            size, EIP170, string.concat(name, " exceeds EIP-170 and cannot be deployed at all")
        );
        headroom = EIP170 - size;
        console2.log(name, size, headroom);
        assertLt(
            size, EIP170 - HEADROOM, string.concat(name, " is within a kilobyte of the ceiling")
        );
    }

    /// @dev Substring search over bytecode. Naive on purpose: the compiler embeds a sub-contract's
    ///      creation code verbatim, so each needle is either present exactly or absent entirely,
    ///      and a needle longer than the haystack is answered without looking.
    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || needle.length > haystack.length) return false;
        uint256 last = haystack.length - needle.length;
        for (uint256 i; i <= last; ++i) {
            bool hit = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
