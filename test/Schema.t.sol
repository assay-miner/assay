// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Bytecode} from "./Bytecode.sol";
import {VaultUISchema, VaultMethodSchema} from "../src/flap/IVaultSchemasV1.sol";
import {Tournament} from "../src/Tournament.sol";

/// @notice The schema is what a generic UI renders from, so the tests are about shape rather than
///         prose: does every named method exist, and is the array-view/write-method pairing that
///         produces cards-with-buttons actually there.
contract SchemaTest is BaseTest {
    /// @dev A schema whose bytecode compiles but whose contract exceeds EIP-170 fails only at
    ///      deployment — every test still green. The fixture deploys the tournament for real, so
    ///      reaching this assertion at all is the size check; this pins the margin explicitly.
    function test_TournamentIsDeployableUnderEip170() public {
        uint256 size = address(tournament).code.length;
        assertLt(size, 24_576, "runtime must fit EIP-170");
        emit log_named_uint("tournament runtime bytes", size);
        emit log_named_uint("eip-170 headroom", 24_576 - size);
    }

    function test_SchemaDecodesAndNamesEveryMethod() public view {
        VaultUISchema memory s = tournament.vaultUISchema();
        assertEq(s.vaultType, "AssayTournament", "vault type");
        assertGt(bytes(s.description).length, 0, "has a description");
        assertEq(s.methods.length, 7, "seven methods");

        string[7] memory expected =
            ["getTasks", "claim", "getMiners", "previewAssay", "commit", "reveal", "postTask"];
        for (uint256 i; i < 7; ++i) {
            assertEq(s.methods[i].name, expected[i], "method name in order");
            assertGt(bytes(s.methods[i].description).length, 0, "every method is described");
        }
    }

    /// @dev The pairing that turns a flat column of numbers into a list of cards with buttons.
    function test_ArrayViewsArePairedWithWriteMethods() public view {
        VaultUISchema memory s = tournament.vaultUISchema();

        uint256 arrayViews;
        uint256 writes;
        for (uint256 i; i < s.methods.length; ++i) {
            VaultMethodSchema memory m = s.methods[i];
            if (m.isOutputArray) {
                arrayViews++;
                assertFalse(m.isWriteMethod, "an array view is a read");
                assertGt(m.outputs.length, 0, "an array view has columns");
            }
            if (m.isWriteMethod) {
                writes++;
                assertEq(m.outputs.length, 0, "a write returns nothing to the UI");
            }
        }
        assertGe(arrayViews, 2, "at least the task list and the leaderboard");
        assertGe(writes, 1, "at least one button to put on the cards");
    }

    /// @dev `postTask` is open to anyone, but not evenly: the curator and Guardian may post at any
    ///      time, and a stranger only in the gap between epochs and only for a short window. That
    ///      asymmetry is not a field this schema format has room for, so the description is the
    ///      only place it can be said. Delete the note and this fails, which is the point — the
    ///      words are the only warning a stranger gets before a click that reverts outside the
    ///      window.
    function test_PostTaskWarnsNonCuratorsOfTheOpenWindow() public view {
        VaultUISchema memory s = tournament.vaultUISchema();
        VaultMethodSchema memory post = s.methods[6];
        assertEq(post.name, "postTask");
        assertTrue(_contains(post.description, "non-curator"), "postTask does not warn a stranger");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) { ok = false; break; }
            }
            if (ok) return true;
        }
        return false;
    }

    /// @dev Without this the UI would ask a user to approve by hand before escrowing a pot.
    function test_PostTaskDeclaresItsApproval() public view {
        VaultUISchema memory s = tournament.vaultUISchema();
        VaultMethodSchema memory post = s.methods[6];
        assertEq(post.name, "postTask");
        assertEq(post.approvals.length, 1, "one approve to send first");
        assertEq(post.approvals[0].tokenType, "taxToken", "resolved via taxToken()");
        assertEq(post.approvals[0].amountFieldName, "pot", "amount comes from the pot field");

        // And the resolver the UI will call must actually answer.
        assertEq(tournament.taxToken(), address(token), "taxToken resolves to the asset");
    }

    /// Every method the schema advertises must be callable, or the page renders dead controls.
    function test_EveryAdvertisedMethodActuallyExists() public {
        _enroll(ALICE, AGENT_ALICE);

        tournament.getTasks(ALICE, 0, 10);
        tournament.getMiners(taskId, 0, 10);
        tournament.previewAssay(taskId, Bytecode.tight());
        tournament.taxToken();
        tournament.description();

        vm.prank(ALICE);
        tournament.commit(taskId, _commitment(Bytecode.tight(), bytes32("a"), AGENT_ALICE));
        vm.warp(commitEnd);
        vm.prank(ALICE);
        tournament.reveal(taskId, Bytecode.tight(), bytes32("a"));
        vm.warp(revealEnd);
        vm.prank(ALICE);
        tournament.claim(taskId);
    }

    function test_TaskCardsCarryWhatACardNeeds() public {
        _enroll(ALICE, AGENT_ALICE);
        _commit(ALICE, AGENT_ALICE, Bytecode.tight(), bytes32("a"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.tight(), bytes32("a"));

        Tournament.TaskCard[] memory page = tournament.getTasks(ALICE, 0, 10);
        assertEq(page.length, 1, "one task");
        assertEq(page[0].taskId, taskId);
        assertEq(page[0].baselineGas, baselineGas);
        assertEq(page[0].vectors, inputs.length, "vector count is on the card");
        assertEq(page[0].entrants, 1, "one scoring miner");
        assertEq(page[0].phase, 1, "revealing");
        assertGt(page[0].yourScore, 0, "the card knows your score");

        vm.warp(revealEnd);
        page = tournament.getTasks(ALICE, 0, 10);
        assertEq(page[0].phase, 2, "settled");
        assertGt(page[0].yourClaimable, 0, "and what the button will pay");
    }

    function test_LeaderboardIsSortedBestFirst() public {
        _enroll(ALICE, AGENT_ALICE);
        _enroll(BOB, AGENT_BOB);
        _commit(ALICE, AGENT_ALICE, Bytecode.padded(), bytes32("a"));
        _commit(BOB, AGENT_BOB, Bytecode.tight(), bytes32("b"));
        vm.warp(commitEnd);
        _reveal(ALICE, Bytecode.padded(), bytes32("a"));
        _reveal(BOB, Bytecode.tight(), bytes32("b"));

        Tournament.MinerCard[] memory page = tournament.getMiners(taskId, 0, 10);
        assertEq(page.length, 2, "two miners");
        assertEq(page[0].miner, BOB, "the tighter submission is first");
        assertGt(page[0].score, page[1].score, "sorted by score");
        assertLt(page[0].gasUsed, page[1].gasUsed, "which means less gas");
    }

    function test_PaginationDoesNotRunOffTheEnd() public view {
        assertEq(tournament.getTasks(ALICE, 99, 10).length, 0, "past the end is empty");
        assertEq(tournament.getMiners(taskId, 99, 10).length, 0, "past the end is empty");
        assertEq(tournament.getTasks(ALICE, 0, 1).length, 1, "limit is respected");
    }
}
