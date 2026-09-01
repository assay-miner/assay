// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title TaskGen
/// @notice Draws a fresh straight-line program each epoch and compiles it two ways: the literal
///         translation anybody writes first, and a peephole-optimised version.
///
/// @dev A task whose function never changes is solved once and replayed forever. The commit
///      window stops meaning anything, because the answer was found weeks earlier — the miner is
///      only racing to resubmit it. So the function itself is drawn fresh from a seed nobody
///      controls, and the baseline is set to what the literal translation of *that* program
///      costs. Scoring therefore requires searching the instance, inside the window, every time.
///
///      The constants are deliberately biased toward values that create algebraic slack —
///      identities, powers of two, foldable neighbours — so that every instance is beatable. Which
///      opcode carries the slack moves with the draw, which is the part a precomputed answer
///      cannot follow.
library TaskGen {
    uint8 internal constant ADD = 0;
    uint8 internal constant MUL = 1;
    uint8 internal constant XOR = 2;
    uint8 internal constant AND = 3;
    uint8 internal constant OR = 4;
    uint8 internal constant SHL = 5;
    uint8 internal constant SHR = 6;
    uint8 internal constant NOT = 7;

    struct Op {
        uint8 kind;
        uint256 c;
    }

    // ---------------------------------------------------------------- semantics

    /// @notice The meaning of one op. The constant sits on top of the stack, so a non-commutative
    ///         op reads as `f(c, acc)` — this is the definition the compiler below must match.
    function step(Op memory o, uint256 acc) internal pure returns (uint256) {
        unchecked {
            if (o.kind == ADD) return o.c + acc;
            if (o.kind == MUL) return o.c * acc;
            if (o.kind == XOR) return o.c ^ acc;
            if (o.kind == AND) return o.c & acc;
            if (o.kind == OR) return o.c | acc;
            if (o.kind == SHL) return o.c >= 256 ? 0 : acc << o.c;
            if (o.kind == SHR) return o.c >= 256 ? 0 : acc >> o.c;
            return ~acc; // NOT
        }
    }

    function eval(Op[] memory ops, uint256 x) internal pure returns (uint256 acc) {
        acc = x;
        for (uint256 i; i < ops.length; ++i) acc = step(ops[i], acc);
    }

    // ---------------------------------------------------------------- drawing

    function _next(uint256 s) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(s)));
    }

    /// @dev Biased so that identities and powers of two turn up often enough that every drawn
    ///      program has slack, without the distribution being so narrow that one cached answer
    ///      covers the space.
    function _constant(uint256 r, uint8 kind) private pure returns (uint256) {
        uint256 pick = r % 100;
        if (kind == SHL || kind == SHR) {
            if (pick < 20) return 0; // identity
            return (r >> 8) % 64; // keep the value from vanishing entirely
        }
        if (pick < 14) return kind == MUL ? 1 : (kind == AND ? type(uint256).max : 0); // identity
        if (pick < 34) return uint256(1) << ((r >> 8) % 200); // power of two
        if (pick < 44) return (r >> 16) % 256; // small
        return r;
    }

    function draw(uint256 seed, uint256 nOps) internal pure returns (Op[] memory ops) {
        ops = new Op[](nOps);
        uint256 s = seed;
        for (uint256 i; i < nOps; ++i) {
            s = _next(s);
            uint8 kind = uint8(s % 8);
            s = _next(s);
            ops[i] = Op({kind: kind, c: kind == NOT ? 0 : _constant(s, kind)});
        }
    }

    // ---------------------------------------------------------------- compiling

    function _push(uint256 c) private pure returns (bytes memory) {
        if (c == 0) return hex"5f"; // PUSH0, 2 gas against PUSH1 0x00's 3
        return abi.encodePacked(hex"7f", bytes32(c)); // PUSH32
    }

    function _opcode(uint8 kind) private pure returns (bytes1) {
        if (kind == ADD) return 0x01;
        if (kind == MUL) return 0x02;
        if (kind == XOR) return 0x18;
        if (kind == AND) return 0x16;
        if (kind == OR) return 0x17;
        if (kind == SHL) return 0x1b;
        if (kind == SHR) return 0x1c;
        return 0x19; // NOT
    }

    /// @notice The literal translation: every constant a PUSH32, every op emitted, nothing folded.
    /// @dev This is what the baseline is measured from, so a submission that does no searching at
    ///      all lands exactly on the baseline and scores zero.
    function compileNaive(Op[] memory ops) internal pure returns (bytes memory code) {
        code = hex"600035"; // PUSH1 0x00, CALLDATALOAD
        for (uint256 i; i < ops.length; ++i) {
            if (ops[i].kind == NOT) {
                code = abi.encodePacked(code, _opcode(NOT));
            } else {
                code = abi.encodePacked(code, hex"7f", bytes32(ops[i].c), _opcode(ops[i].kind));
            }
        }
        // PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
        code = abi.encodePacked(code, hex"60005260206000f3");
    }

    /// @notice The optimised translation: PUSH0 where a zero is wanted, folded op list.
    function compileTight(Op[] memory ops) internal pure returns (bytes memory code) {
        code = hex"5f35"; // PUSH0, CALLDATALOAD
        for (uint256 i; i < ops.length; ++i) {
            if (ops[i].kind == NOT) {
                code = abi.encodePacked(code, _opcode(NOT));
            } else {
                code = abi.encodePacked(code, _push(ops[i].c), _opcode(ops[i].kind));
            }
        }
        // PUSH0 MSTORE PUSH1 0x20 PUSH0 RETURN
        //
        code = abi.encodePacked(code, hex"5f5260205ff3");
    }

    /// @notice A reference peephole pass. Miners are free to do better; this only has to prove the
    ///         drawn instance is beatable before it is posted.
    function optimise(Op[] memory ops) internal pure returns (Op[] memory out) {
        Op[] memory buf = new Op[](ops.length);
        uint256 n;

        for (uint256 i; i < ops.length; ++i) {
            // A copy, not a reference. `Op memory o = ops[i]` aliases the caller's array, so the
            // folding below would rewrite the very program this is meant to be optimising — the
            // baseline would then be measured against one program and the vectors published for
            // another.
            Op memory o = Op({kind: ops[i].kind, c: ops[i].c});

            // 1 — identities disappear.
            if (o.kind == ADD && o.c == 0) continue;
            if (o.kind == XOR && o.c == 0) continue;
            if (o.kind == OR && o.c == 0) continue;
            if (o.kind == MUL && o.c == 1) continue;
            if (o.kind == AND && o.c == type(uint256).max) continue;
            if ((o.kind == SHL || o.kind == SHR) && o.c == 0) continue;

            // 2 — NOT NOT cancels.
            if (o.kind == NOT && n > 0 && buf[n - 1].kind == NOT) {
                --n;
                continue;
            }

            // 3 — a constant op folds into its neighbour of the same kind.
            if (n > 0 && buf[n - 1].kind == o.kind && o.kind != NOT) {
                Op memory p = buf[n - 1];
                unchecked {
                    if (o.kind == ADD) { p.c += o.c; buf[n - 1] = p; continue; }
                    if (o.kind == MUL) { p.c *= o.c; buf[n - 1] = p; continue; }
                    if (o.kind == XOR) { p.c ^= o.c; buf[n - 1] = p; continue; }
                    if (o.kind == AND) { p.c &= o.c; buf[n - 1] = p; continue; }
                    if (o.kind == OR)  { p.c |= o.c; buf[n - 1] = p; continue; }
                    // Shifts fold the same way and were the one pair left out. The data says they
                    // are also the pair that actually turns up: a drawn program of nine ops lands
                    // two adjacent shifts often enough to be the cheapest instruction available.
                }
            }

            // 4 — multiplying by a power of two is a shift: MUL's 5 gas against SHL's 3.
            if (o.kind == MUL && o.c != 0 && (o.c & (o.c - 1)) == 0) {
                uint256 k;
                uint256 v = o.c;
                while (v > 1) { v >>= 1; ++k; }
                o = Op({kind: SHL, c: k});
            }

            // A live-bit pass sat here and is gone. It tracked which bits could still be
            // non-zero and dropped masks that could not matter — sound in principle, wrong twice
            // in practice, because the folding rules above rewrite entries after the tracking has
            // read them. It also bought nothing measurable on the drawn programs. The gain in this
            // pass is entirely the shift folding below it.
            buf[n++] = o;
        }
        out = new Op[](n);
        for (uint256 i; i < n; ++i) out[i] = buf[i];
    }
}
