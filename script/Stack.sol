// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {AgentRoster} from "../src/AgentRoster.sol";
import {AssayFlapFactory} from "../src/AssayFlapFactory.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {TaskGenerator} from "../src/TaskGenerator.sol";
import {Tournament} from "../src/Tournament.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";

/// @notice Assembles the whole ASSAY stack behind beacons, in one place, for both the deploy script
///         and the test fixture.
///
/// @dev Flap requires every contract to be upgradeable with the upgrade authority held by their
///      Guardian, so each contract is now an implementation behind an `UpgradeableBeacon` the
///      Guardian owns, and the address the rest of the system knows is a `BeaconProxy`. Only
///      `TaskGenerator` was shaped this way before; the reason it is worth having a single assembler
///      rather than seven repetitions of the pattern is that the ORDER below is load-bearing, and an
///      order that is written twice is an order that will eventually be written two ways.
///
///      Every proxy is constructed WITH its initializer calldata. That is not a style choice. A
///      `forge script` broadcast is N separate transactions, so a proxy deployed with empty init
///      data sits uninitialized across a block boundary, and none of these initializers has access
///      control — anyone watching could land `initialize(their own vault)` in that gap and own the
///      contract permanently. Constructing and initializing in one call closes the gap for six of
///      the seven.
///
///      The seventh is a genuine cycle: `Tournament.initialize` takes the generator and
///      `TaskGenerator.initialize` takes the tournament. It is broken by PREDICTING the generator
///      proxy's address rather than by deferring its initialization, so the gap never opens there
///      either. The prediction only holds if the generator proxy is the very next CREATE from this
///      account after the tournament proxy — which is why those two lines sit together with nothing
///      between them, and why the assertion after them is not decoration.
///
///      `deployer` is passed in rather than read from `msg.sender`. Inside an internal library
///      function the CREATEs are performed by the caller, so `msg.sender` here is whoever called
///      the caller — under `vm.startBroadcast` that is not the broadcasting key. The contracts that
///      record a deployer would have recorded the wrong one.
library Stack {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The beacon behind each contract. Every one is owned by Flap's Guardian, and every
    ///         one is the only place that contract's code can be replaced from.
    struct Beacons {
        address priceGuard;
        address vault;
        address roster;
        address tournament;
        address generator;
        address flapVault;
        address factory;
    }

    /// @notice The implementation behind each beacon. Held only so a deployment can be audited
    ///         against its source; nothing addresses these directly.
    struct Impls {
        address priceGuard;
        address vault;
        address roster;
        address tournament;
        address generator;
        address flapVault;
        address factory;
    }

    struct Deployed {
        PriceGuard priceGuard;
        AssayVault vault;
        AgentRoster roster;
        Tournament tournament;
        TaskGenerator generator;
        AssayFlapFactory factory;
        Beacons beacons;
        Impls impls;
    }

    struct Params {
        address deployer;
        address guardian;
        address asset;
        address salvage;
        address registry;
        uint256 minStake;
        address curator;
    }

    /// @notice Flap's Guardian for this chain — the address that owns every beacon below.
    ///
    /// @dev The same table `Tournament._getGuardian` uses. It is here so no call site has to carry
    ///      its own copy of the address: a fixture that hardcodes the testnet Guardian and a script
    ///      that hardcodes mainnet's are two places to get one fact wrong, and the wrong Guardian is
    ///      not a failing test, it is a beacon nobody at Flap can upgrade.
    ///
    ///      Unknown chains get `address(0)`, which is deliberate and matches `_getGuardian`: on a
    ///      local chain there is no Flap, and a beacon owned by nobody is the honest representation
    ///      of that. `UpgradeableBeacon` rejects a zero owner, so a real deployment to an unknown
    ///      chain fails loudly at construction rather than shipping an unownable beacon.
    function guardian() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 56) return 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        if (chainId == 97) return 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        return address(0);
    }

    /// @dev One implementation, one beacon owned by the Guardian, one proxy initialized in the same
    ///      call that creates it.
    function behindBeacon(address impl, address guardian_, bytes memory initData)
        internal
        returns (address beacon, address proxy)
    {
        beacon = address(new UpgradeableBeacon(impl, guardian_));
        proxy = address(new BeaconProxy(beacon, initData));
    }

    // One typed helper per contract. Scripts and tests that need a single contract rather than the
    // whole stack build it through these, so there is exactly one expression in the repository that
    // knows how any given contract is put together. Before this, six files each wrote `new X(...)`
    // and a seventh wrote the beacon dance, which is how the fixture and the deploy script drifted
    // into claiming to match while nothing checked.

    function newPriceGuard(address guardian_) internal returns (PriceGuard) {
        (, address proxy) =
            behindBeacon(address(new PriceGuard()), guardian_, abi.encodeCall(PriceGuard.initialize, ()));
        return PriceGuard(proxy);
    }

    function newVault(address guardian_, address asset, address salvage, address deployer)
        internal
        returns (AssayVault)
    {
        (, address proxy) = behindBeacon(
            address(new AssayVault()),
            guardian_,
            abi.encodeCall(AssayVault.initialize, (IERC20(asset), salvage, deployer))
        );
        return AssayVault(proxy);
    }

    function newRoster(
        address guardian_,
        address registry,
        AssayVault vault,
        uint256 minStake,
        address deployer
    ) internal returns (AgentRoster) {
        (, address proxy) = behindBeacon(
            address(new AgentRoster()),
            guardian_,
            abi.encodeCall(
                AgentRoster.initialize, (IIdentityRegistry(registry), vault, minStake, deployer)
            )
        );
        return AgentRoster(proxy);
    }

    function newTournament(
        address guardian_,
        AssayVault vault,
        AgentRoster roster,
        address curator,
        address generator
    ) internal returns (Tournament) {
        (, address proxy) = behindBeacon(
            address(new Tournament()),
            guardian_,
            abi.encodeCall(Tournament.initialize, (vault, roster, curator, generator))
        );
        return Tournament(proxy);
    }

    /// @notice The tournament and its generator, which name each other.
    ///
    /// @dev The only place in the repository that writes the address prediction. Two test fixtures
    ///      used to write their own, predicting `nonce + 1` because a tournament was one CREATE;
    ///      behind a beacon it is three, and the prediction silently pointed at the beacon instead
    ///      of the proxy. Rather than teach every caller how many CREATEs a helper performs — which
    ///      is Stack's internals copied to a distance, and would break again the next time one of
    ///      them changes — the pair is built here and the count never leaves this function.
    ///
    ///      Returns the generator's beacon too, because a caller that wants to exercise upgrading
    ///      the generator needs it and building a second one would be testing a beacon nothing uses.
    function newTournamentAndGenerator(
        address guardian_,
        AssayVault vault,
        AgentRoster roster,
        address curator,
        address deployer
    )
        internal
        returns (Tournament t, TaskGenerator g, address tournamentBeacon, address generatorBeacon)
    {
        address genImpl = address(new TaskGenerator());
        generatorBeacon = address(new UpgradeableBeacon(genImpl, guardian_));
        address tourImpl = address(new Tournament());
        tournamentBeacon = address(new UpgradeableBeacon(tourImpl, guardian_));

        // Adjacent CREATEs. Nothing may be inserted between these two statements.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        t = Tournament(
            address(
                new BeaconProxy(
                    tournamentBeacon,
                    abi.encodeCall(Tournament.initialize, (vault, roster, curator, predicted))
                )
            )
        );
        g = TaskGenerator(
            address(new BeaconProxy(generatorBeacon, abi.encodeCall(TaskGenerator.initialize, (t))))
        );
        require(address(g) == predicted, "generator address prediction missed");
        require(t.generator() == address(g), "tournament points at the wrong generator");
    }

    function newFlapVault(
        address guardian_,
        Tournament tournament,
        address taxToken,
        address curator,
        PriceGuard priceGuard
    ) internal returns (AssayFlapVault) {
        (, address proxy) = behindBeacon(
            address(new AssayFlapVault()),
            guardian_,
            abi.encodeCall(AssayFlapVault.initialize, (tournament, taxToken, curator, priceGuard))
        );
        return AssayFlapVault(payable(proxy));
    }

    function newFactory(address guardian_, Tournament tournament, PriceGuard priceGuard, address vaultBeacon)
        internal
        returns (AssayFlapFactory)
    {
        (, address proxy) = behindBeacon(
            address(new AssayFlapFactory()),
            guardian_,
            abi.encodeCall(AssayFlapFactory.initialize, (tournament, priceGuard, vaultBeacon))
        );
        return AssayFlapFactory(proxy);
    }

    /// @notice The contracts that do not touch Flap: custody, the roster, the tournament and the
    ///         generator that feeds it.
    ///
    /// @dev Split out from `deploy` because `PriceGuard.initialize` resolves a router from
    ///      `block.chainid` and reverts with "Bad chain" anywhere Flap is not deployed. The test
    ///      fixture runs on the local chain and never needed a price guard; folding one into its
    ///      setup made twenty suites fail at `setUp` for a contract none of them used. The split is
    ///      what the fixture actually needs rather than a relaxation of that guard — a router that
    ///      can be supplied is a router that can be answered with, which is the reason the guard
    ///      reads the chain instead of a parameter.
    function deployCore(Params memory p) internal returns (Deployed memory d) {
        address proxy;

        d.impls.vault = address(new AssayVault());
        (d.beacons.vault, proxy) = behindBeacon(
            d.impls.vault,
            p.guardian,
            abi.encodeCall(AssayVault.initialize, (IERC20(p.asset), p.salvage, p.deployer))
        );
        d.vault = AssayVault(proxy);

        d.impls.roster = address(new AgentRoster());
        (d.beacons.roster, proxy) = behindBeacon(
            d.impls.roster,
            p.guardian,
            abi.encodeCall(
                AgentRoster.initialize,
                (IIdentityRegistry(p.registry), d.vault, p.minStake, p.deployer)
            )
        );
        d.roster = AgentRoster(proxy);

        (d.tournament, d.generator, d.beacons.tournament, d.beacons.generator) =
            newTournamentAndGenerator(p.guardian, d.vault, d.roster, p.curator, p.deployer);
        // Read back rather than threaded out of the helper: the beacon IS where the implementation
        // is recorded, so asking it cannot disagree with what the proxy actually delegates to.
        d.impls.tournament = UpgradeableBeacon(d.beacons.tournament).implementation();
        d.impls.generator = UpgradeableBeacon(d.beacons.generator).implementation();

    }

    /// @notice The Flap-facing half: the price guard, the vault beacon every launched token's vault
    ///         is minted against, and the factory Flap's portal calls.
    ///
    /// @dev Only runs where Flap is: `PriceGuard.initialize` refuses any other chain. Takes the core
    ///      it attaches to rather than rebuilding it, so a caller cannot end up with a factory
    ///      pointing at a different tournament than the one it deployed.
    ///      Returns the struct rather than mutating in place: a caller holding `Deployed` in
    ///      storage passes a memory copy, and writes to that copy are discarded. `deploy` below
    ///      happens to work either way because its own `d` is already memory, which is exactly the
    ///      kind of difference that makes one caller silently get nothing.
    function deployFlap(Params memory p, Deployed memory d) internal returns (Deployed memory) {
        address proxy;

        d.impls.priceGuard = address(new PriceGuard());
        (d.beacons.priceGuard, proxy) =
            behindBeacon(d.impls.priceGuard, p.guardian, abi.encodeCall(PriceGuard.initialize, ()));
        d.priceGuard = PriceGuard(proxy);

        // The flap vault has an implementation and a beacon but no proxy here: one proxy per token
        // is created by the factory, in `newVault`, when Flap's portal launches a token.
        d.impls.flapVault = address(new AssayFlapVault());
        d.beacons.flapVault = address(new UpgradeableBeacon(d.impls.flapVault, p.guardian));

        d.impls.factory = address(new AssayFlapFactory());
        (d.beacons.factory, proxy) = behindBeacon(
            d.impls.factory,
            p.guardian,
            abi.encodeCall(
                AssayFlapFactory.initialize, (d.tournament, d.priceGuard, d.beacons.flapVault)
            )
        );
        d.factory = AssayFlapFactory(proxy);
        return d;
    }

    /// @notice The whole stack. What `script/Deploy.s.sol` broadcasts.
    function deploy(Params memory p) internal returns (Deployed memory d) {
        d = deployCore(p);
        d = deployFlap(p, d);
    }

    /// @notice Custody wiring, then sealed. Separated from `deploy` because the deployer key has to
    ///         be the caller of these, and a test fixture and a broadcast reach that differently.
    function wire(Deployed memory d) internal {
        d.vault.addController(address(d.roster));
        d.vault.addController(address(d.tournament));
        d.vault.freeze();
        d.roster.setConsumer(address(d.tournament));
    }
}
