// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Crucible} from "../src/Crucible.sol";
import {CrucibleHarness} from "../test/CrucibleHarness.sol";
import {TaskGen} from "../src/TaskGen.sol";

/// @notice Draws one epoch's task, measures its baseline on a real EVM, and writes the spec.
///
/// @dev The baseline is never asserted from a table. Both the literal translation and the
///      reference optimisation are deployed and run through the same Crucible the tournament
///      scores with, and the numbers that come back are the numbers written to the file. A
///      closed-form gas model would drift the first time an opcode's price changed.
contract GenTask is Script {
    uint256 constant OPS = 9;
    uint256 constant VECTORS = 8;
    uint256 constant GAS_CAP = 100_000;
    /// @dev A drawn instance is only posted if the reference pass beats the literal one by at
    ///      least this much, so an epoch can never be unwinnable.
    uint256 constant MIN_MARGIN = 30;
    uint256 constant MAX_DRAWS = 64;

    function run() external {
        uint256 seed = vm.envOr("SEED", uint256(0));
        if (seed == 0) revert(unicode"SEED is required / 需要 SEED");
        string memory out = vm.envOr("OUT", string("tasks/epoch.json"));

        CrucibleHarness h = new CrucibleHarness();

        TaskGen.Op[] memory ops;
        bytes memory naive;
        uint256 baseGas;
        uint256 tightGas;
        uint256 draws;

        // Redraw until the instance has real slack. The seed advances rather than restarting, so
        // the search is reproducible from the recorded seed and draw count.
        for (draws = 0; draws < MAX_DRAWS; ++draws) {
            ops = TaskGen.draw(uint256(keccak256(abi.encode(seed, draws))), OPS);
            Crucible.Vector[] memory probe = _vectors(seed, ops);
            naive = TaskGen.compileNaive(ops);
            bytes memory tight = TaskGen.compileTight(TaskGen.optimise(ops));

            (bool okA, uint256 gA,) = h.measure(naive, probe, GAS_CAP);
            (bool okB, uint256 gB,) = h.measure(tight, probe, GAS_CAP);
            // Both must agree on every vector: an "optimisation" that changes the answer is a bug,
            // and shipping it would post a task whose stated baseline nothing can legally reach.
            if (okA && okB && gA > gB && gA - gB >= MIN_MARGIN && _informative(probe)) {
                baseGas = gA;
                tightGas = gB;
                break;
            }
        }
        if (baseGas == 0) revert(unicode"No beatable instance drawn / 未抽到可优化的实例");

        Crucible.Vector[] memory vec = _vectors(seed, ops);
        _write(out, seed, draws, ops, vec, baseGas, tightGas);

        console2.log("draws          ", draws);
        console2.log("baselineGas    ", baseGas);
        console2.log("reference best ", tightGas);
        console2.log("margin         ", baseGas - tightGas);
    }

    /// @dev A drawn program can destroy its input — an AND against a single bit followed by a
    ///      shift past that bit leaves the same answer for almost every input. Posting one of
    ///      those hands the epoch to whoever returns the constant, without computing anything. So
    ///      an instance is only accepted when every vector produces a distinct output.
    function _informative(Crucible.Vector[] memory v) internal pure returns (bool) {
        for (uint256 i; i < v.length; ++i) {
            for (uint256 j = i + 1; j < v.length; ++j) {
                if (v[i].expected == v[j].expected) return false;
            }
        }
        return true;
    }

    /// @dev Vectors are drawn from the same seed and include the three inputs that make a
    ///      table-driven answer impossible to hide: zero, one, and a value with the high bits set.
    function _vectors(uint256 seed, TaskGen.Op[] memory ops)
        internal
        pure
        returns (Crucible.Vector[] memory v)
    {
        v = new Crucible.Vector[](VECTORS);
        for (uint256 i; i < VECTORS; ++i) {
            uint256 x;
            if (i == 0) x = 0;
            else if (i == 1) x = 1;
            else if (i == 2) x = type(uint256).max;
            else x = uint256(keccak256(abi.encode(seed, "vec", i)));
            v[i] = Crucible.Vector({
                input: abi.encodePacked(bytes32(x)),
                expected: keccak256(abi.encodePacked(bytes32(TaskGen.eval(ops, x))))
            });
        }
    }

    function _write(
        string memory out,
        uint256 seed,
        uint256 draws,
        TaskGen.Op[] memory ops,
        Crucible.Vector[] memory v,
        uint256 baseGas,
        uint256 tightGas
    ) internal {
        string memory ins = "";
        string memory exp = "";
        for (uint256 i; i < v.length; ++i) {
            string memory comma = i + 1 == v.length ? "" : ",";
            ins = string.concat(ins, '    "', vm.toString(v[i].input), '"', comma, "\n");
            exp = string.concat(exp, '    "', vm.toString(v[i].expected), '"', comma, "\n");
        }

        string memory prog = "";
        for (uint256 i; i < ops.length; ++i) {
            prog = string.concat(
                prog,
                '    "',
                _name(ops[i].kind),
                " ",
                vm.toString(ops[i].c),
                '"',
                i + 1 == ops.length ? "" : ",",
                "\n"
            );
        }

        string memory json = string.concat(
            "{\n",
            '  "name": "epoch",\n',
            '  "description": "Apply this epoch\'s program to a uint256 read from calldata and return the result as 32 raw bytes.",\n',
            '  "seed": "', vm.toString(bytes32(seed)), '",\n',
            '  "draws": ', vm.toString(draws), ",\n",
            '  "program": [\n', prog, "  ],\n",
            '  "inputs": [\n', ins, "  ],\n",
            '  "expected": [\n', exp, "  ],\n",
            // The bytes the baseline is measured from. postTask derives the difficulty by running
            // this against these vectors, so the number below is a prediction the poster checks
            // against what the chain records rather than a figure the task is told to believe.
            '  "referenceRuntime": "', vm.toString(TaskGen.compileNaive(ops)), '",\n',
            '  "baselineGas": ', vm.toString(baseGas), ",\n",
            '  "referenceGas": ', vm.toString(tightGas), ",\n",
            '  "gasCap": ', vm.toString(GAS_CAP), ",\n",
            '  "commitSeconds": 60,\n',
            '  "revealSeconds": 60,\n',
            '  "pot": "0"\n',
            "}\n"
        );
        vm.writeFile(out, json);
    }

    function _name(uint8 k) internal pure returns (string memory) {
        if (k == TaskGen.ADD) return "ADD";
        if (k == TaskGen.MUL) return "MUL";
        if (k == TaskGen.XOR) return "XOR";
        if (k == TaskGen.AND) return "AND";
        if (k == TaskGen.OR) return "OR";
        if (k == TaskGen.SHL) return "SHL";
        if (k == TaskGen.SHR) return "SHR";
        return "NOT";
    }
}
