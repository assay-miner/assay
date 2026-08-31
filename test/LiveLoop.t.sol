// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Tournament} from "../src/Tournament.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {AssayVault} from "../src/AssayVault.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {Crucible} from "../src/Crucible.sol";
import {TaskGen} from "../src/TaskGen.sol";

/// @notice One full epoch against the contracts actually deployed on BNB testnet.
///
/// @dev The unit suite builds its own stack, so it proves the code. This proves the deployment:
///      the same addresses a miner would call, wired the way the deploy script left them. The one
///      thing it has to fake is acquiring the token — Flap's testnet Portal answers
///      `FeatureDisabled()` to `buy`, for our token and for the one launched before it, so nobody
///      can obtain it there by trading. On mainnet that is the Portal's whole purpose.
contract LiveLoopTest is Test {
    // Read from the manifest, not typed in. These were five constants naming a deployment two
    // redeploys ago, which meant the suite was quietly testing something that no longer existed.
    address internal TOURNAMENT;
    address internal ROSTER;
    address internal CUSTODY;
    address internal FLAP_VAULT;
    address internal TAX_TOKEN;
    address constant REGISTRY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address constant BTCB = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8;
    address constant CURATOR = 0x70281A8587452E898A60b08fcee10963999bCeA3;
    address constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;

    uint32 constant GAS_CAP = 100_000;
    uint256 constant OPS = 9;

    Tournament t = Tournament(TOURNAMENT);
    AgentRoster r = AgentRoster(ROSTER);
    AssayFlapVault flap = AssayFlapVault(payable(FLAP_VAULT));

    address miner = address(uint160(uint256(keccak256("miner"))));

    function setUp() public {
        vm.createSelectFork(vm.envOr("BSC_TESTNET_RPC", string("https://bsc-testnet-rpc.publicnode.com")));
        string memory manifest = vm.readFile("deployments/97-latest.json");
        TOURNAMENT = vm.parseJsonAddress(manifest, ".tournament");
        ROSTER = vm.parseJsonAddress(manifest, ".roster");
        CUSTODY = vm.parseJsonAddress(manifest, ".vault");
        FLAP_VAULT = vm.parseJsonAddress(manifest, ".flapVault");
        TAX_TOKEN = vm.parseJsonAddress(manifest, ".taxToken");
    }

    /// True when the deployed tournament is built from this tree rather than an older one.
    function _deploymentIsCurrent() internal view returns (bool ok) {
        (ok,) = TOURNAMENT.staticcall(abi.encodeWithSignature("OPEN_POST_MAX_SPAN()"));
    }

    function test_OneEpochEndToEnd() public {
        // The loop needs a launched token to be a loop at all. Neither chain has one right now,
        // deliberately, so this reports that it did nothing rather than passing quietly or failing
        // for a reason that is not a defect. It runs the moment a token exists.
        if (FLAP_VAULT == address(0) || TAX_TOKEN == address(0) || FLAP_VAULT.code.length == 0) {
            emit log("SKIPPED: 97-latest.json has no launched token; nothing to run an epoch against");
            return;
        }
        assertTrue(
            _deploymentIsCurrent(),
            "the deployed tournament predates this tree; redeploy testnet before running this suite"
        );

        // --- the deployment is the single-token one -------------------------------------------
        assertEq(address(AssayVault(CUSTODY).asset()), TAX_TOKEN, "custody is not denominated in the tax token");
        assertEq(flap.taxToken(), TAX_TOKEN, "the flap vault settles a different token");
        assertEq(address(flap.tournament()), TOURNAMENT, "the flap vault points at another tournament");

        // --- draw this epoch's task, exactly as tools/epoch.sh does -----------------------------
        // Mirrors GenTask exactly: redraw until the instance is beatable, and derive from
        // (seed, draws) rather than the seed alone -- which is the derivation the client has to
        // reproduce, and got wrong the first time it was pointed at a live task.
        uint256 seed = uint256(blockhash(block.number - 1));
        TaskGen.Op[] memory ops;
        bytes[] memory ins;
        bytes32[] memory exp;
        uint256 baseline;
        uint256 best;
        for (uint256 draws; draws < 64; ++draws) {
            ops = TaskGen.draw(uint256(keccak256(abi.encode(seed, draws))), OPS);
            (ins, exp) = _vectors(seed, ops);
            uint256 gN = _measure(TaskGen.compileNaive(ops), ins, exp);
            uint256 gT = _measure(TaskGen.compileTight(TaskGen.optimise(ops)), ins, exp);
            if (gN > gT && gN - gT >= 30 && _distinct(exp)) {
                baseline = gN;
                best = gT;
                break;
            }
        }
        assertGt(baseline, best, "no beatable epoch was drawn in 64 tries");

        uint64 commitEnd = uint64(block.timestamp + 60);
        uint64 revealEnd = commitEnd + 60;
        vm.prank(CURATOR);
        // The literal translation is the reference. The chain measures it, so `baseline` above is
        // now a prediction this asserts against rather than a number the task is told to believe.
        uint256 id = t.postTask(ins, exp, TaskGen.compileNaive(ops), GAS_CAP, commitEnd, revealEnd, 0);
        (,,,, uint32 recorded,,,,) = t.tasks(id);
        assertEq(uint256(recorded), baseline, "the chain measured a different baseline than the test did");

        // --- tax arrives and is put behind the task ---------------------------------------------
        vm.deal(address(flap), 0.05 ether);
        uint256 floor_ = (flap.quote(0.05 ether) * 97) / 100;
        vm.prank(GUARDIAN);
        uint256 bounty = flap.endow(id, 0.05 ether, floor_);
        assertGt(bounty, 0, "no bounty was booked");

        // --- a miner buys in, enrols, and mines --------------------------------------------------
        // Standing in for a purchase: on mainnet this is the Portal's job.
        deal(TAX_TOKEN, miner, 2_000e18, true);
        uint256 agentId = 4242;
        vm.mockCall(
            REGISTRY,
            abi.encodeWithSignature("isAuthorizedOrOwner(address,uint256)", miner, agentId),
            abi.encode(true)
        );

        vm.startPrank(miner);
        IERC20(TAX_TOKEN).approve(CUSTODY, type(uint256).max);
        r.enroll(agentId, r.minStake());

        bytes memory answer = TaskGen.compileTight(TaskGen.optimise(ops));
        bytes32 salt = keccak256("nonce");
        t.commit(id, keccak256(abi.encode(answer, salt, agentId)));
        vm.warp(commitEnd);
        t.reveal(id, answer, salt);
        vm.stopPrank();

        (,,,,,,, uint256 totalScore,) = t.tasks(id);
        assertGt(totalScore, 0, "the miner's answer did not score");

        // --- and collects the tax, in BTCB, straight from the vault -------------------------------
        vm.warp(revealEnd);
        uint256 before = IERC20(BTCB).balanceOf(miner);
        vm.prank(miner);
        uint256 got = flap.collect(id);

        assertEq(got, bounty, "the miner did not receive the whole bounty");
        assertEq(IERC20(BTCB).balanceOf(miner), before + got, "the BTCB did not arrive");
        assertTrue(flap.solvent(), "the vault is insolvent after paying");

        console2.log("baseline gas   ", baseline);
        console2.log("miner gas      ", best);
        console2.log("BTCB to miner  ", got);
    }

    function _distinct(bytes32[] memory exp) internal pure returns (bool) {
        for (uint256 i; i < exp.length; ++i) {
            for (uint256 j = i + 1; j < exp.length; ++j) if (exp[i] == exp[j]) return false;
        }
        return true;
    }

    function _vectors(uint256 seed, TaskGen.Op[] memory ops)
        internal
        pure
        returns (bytes[] memory ins, bytes32[] memory exp)
    {
        ins = new bytes[](8);
        exp = new bytes32[](8);
        for (uint256 i; i < 8; ++i) {
            uint256 x = i == 0 ? 0 : (i == 1 ? 1 : (i == 2 ? type(uint256).max
                : uint256(keccak256(abi.encode(seed, "vec", i)))));
            ins[i] = abi.encodePacked(bytes32(x));
            exp[i] = keccak256(abi.encodePacked(bytes32(TaskGen.eval(ops, x))));
        }
    }

    function _measure(bytes memory code, bytes[] memory ins, bytes32[] memory exp)
        internal
        returns (uint256 gasUsed)
    {
        Crucible.Vector[] memory v = new Crucible.Vector[](ins.length);
        for (uint256 i; i < ins.length; ++i) v[i] = Crucible.Vector({input: ins[i], expected: exp[i]});
        address impl = Crucible.deployRuntime(code);
        bool ok;
        (ok, gasUsed) = Crucible.assay(impl, v, GAS_CAP);
        require(ok, "candidate fails its own vectors");
    }
}
