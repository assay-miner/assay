// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Tournament} from "../src/Tournament.sol";
import {AgentRoster} from "../src/AgentRoster.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";
import {Crucible} from "../src/Crucible.sol";
import {TaskGen} from "./TaskGen.sol";

/// @notice The miner. One mode per window, because commit and reveal are different windows.
///
/// @dev The epoch's program is not published as an instruction to be trusted. It is derived from
///      the seed by the same public function that drew it, and then checked against the expected
///      hashes already on chain. If a poster ever announced a program that was not the one behind
///      those hashes, this check fails here and the miner spends nothing — which is why the seed
///      can be handed over an untrusted channel.
contract Mine is Script {
    error ProgramDoesNotMatchTheChain();
    error NothingBeatsTheBaseline(uint256 gas, uint32 baseline);

    function run() external {
        string memory mode = vm.envString("MODE");
        uint256 pk = vm.envUint("MINER_KEY");
        Tournament t = Tournament(vm.envAddress("TOURNAMENT"));
        uint256 taskId = vm.envUint("TASK_ID");
        uint256 agentId = vm.envUint("AGENT_ID");
        bytes32 salt = keccak256(abi.encode(vm.envString("MINER_NONCE"), taskId));

        if (_is(mode, "enroll")) {
            AgentRoster r = AgentRoster(vm.envAddress("ROSTER"));
            IERC20 token = IERC20(vm.envAddress("TOKEN"));
            uint256 stake = r.minStake();
            vm.startBroadcast(pk);
            token.approve(address(r.vault()), stake);
            r.enroll(agentId, stake);
            vm.stopBroadcast();
            console2.log("enrolled agent", agentId, "stake", stake);
            return;
        }

        if (_is(mode, "collect")) {
            AssayFlapVault flap = AssayFlapVault(payable(vm.envAddress("FLAP_VAULT")));
            vm.startBroadcast(pk);
            uint256 got = flap.collect(taskId);
            vm.stopBroadcast();
            console2.log("collected (BTCB wei)", got);
            return;
        }

        // Both commit and reveal need the same answer, and it has to be derived the same way each
        // time or the commitment will not open.
        bytes memory answer = _solve(t, taskId);

        if (_is(mode, "commit")) {
            vm.startBroadcast(pk);
            t.commit(taskId, keccak256(abi.encode(answer, salt, agentId)));
            vm.stopBroadcast();
            console2.log("committed", answer.length, "bytes");
        } else if (_is(mode, "reveal")) {
            vm.startBroadcast(pk);
            t.reveal(taskId, answer, salt);
            vm.stopBroadcast();
            (,,, uint128 score,,) = t.submissions(taskId, vm.addr(pk));
            console2.log("revealed, score", uint256(score));
        } else {
            revert(unicode"MODE must be enroll|commit|reveal|collect / MODE 取值错误");
        }
    }

    /// @dev Derive, check against the chain, optimise, and refuse to submit something that cannot
    ///      score. A submission at or above the baseline is a wasted transaction, not a bad one.
    function _solve(Tournament t, uint256 taskId) internal returns (bytes memory answer) {
        // GenTask redraws until it finds a beatable instance, so the program behind a task is
        // drawn from (seed, draws) — not from the seed alone. Getting this wrong is what the
        // check below exists to catch, and it caught it.
        uint256 seed = vm.envUint("SEED");
        uint256 draws = vm.envOr("DRAWS", uint256(0));
        uint256 nOps = vm.envOr("OPS", uint256(9));
        TaskGen.Op[] memory ops = TaskGen.draw(uint256(keccak256(abi.encode(seed, draws))), nOps);

        uint256 n = t.vectorCount(taskId);
        Crucible.Vector[] memory v = new Crucible.Vector[](n);
        for (uint256 i; i < n; ++i) v[i] = t.vectorAt(taskId, i);
        for (uint256 i; i < v.length; ++i) {
            uint256 x = abi.decode(v[i].input, (uint256));
            if (keccak256(abi.encodePacked(bytes32(TaskGen.eval(ops, x)))) != v[i].expected) {
                revert ProgramDoesNotMatchTheChain();
            }
        }

        answer = TaskGen.compileTight(TaskGen.optimise(ops));

        (,,, uint32 gasCap, uint32 baseline,,,,) = t.tasks(taskId);
        address impl = Crucible.deployRuntime(answer);
        (bool ok, uint256 gas) = Crucible.assay(impl, v, gasCap);
        if (!ok || gas >= baseline) revert NothingBeatsTheBaseline(gas, baseline);
        console2.log("baseline", uint256(baseline), "-> mine", gas);
    }

    function _is(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
