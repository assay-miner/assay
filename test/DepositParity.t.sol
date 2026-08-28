// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {AssayVault} from "../src/AssayVault.sol";

/// @notice Custody credits the nominal amount and then pulls that same amount. That is only
///         correct while a plain transfer of the asset moves exactly what it says.
///
/// @dev The asset is now the launched taxed-V3 token, which is precisely the case SELF_CHECK's
///      I-05 warned about. It is safe because that token taxes pool interactions and not wallet
///      transfers -- but "I measured it once" is not a guarantee that survives a redeploy of the
///      token, so it is asserted here against the live one instead.
contract DepositParityTest is Test {
    address constant TAX_TOKEN = 0x769EfAbeFc18317A846A1E2BdeB831Ba659f7777;
    address constant CUSTODY = 0xecA1e2538b800841735C8fb78912c948Ba075Ee0;

    function test_APlainTransferOfTheAssetIsUntaxed() public {
        vm.createSelectFork(vm.envOr("BSC_TESTNET_RPC", string("https://bsc-testnet-rpc.publicnode.com")));
        assertEq(address(AssayVault(CUSTODY).asset()), TAX_TOKEN, "custody holds a different asset now");

        IERC20 token = IERC20(TAX_TOKEN);
        address from = address(uint160(uint256(keccak256("from"))));
        address to = address(uint160(uint256(keccak256("to"))));
        uint256 amount = 1_000e18;
        deal(TAX_TOKEN, from, amount, true);

        uint256 sent = token.balanceOf(from);
        vm.prank(from);
        token.transfer(to, amount);

        assertEq(token.balanceOf(to), amount, "a plain transfer lost value; custody must move to balance-delta accounting");
        assertEq(sent - token.balanceOf(from), amount, "more left the sender than was sent");
    }

    /// The same through the path custody actually uses.
    function test_TransferFromMovesTheNominalAmount() public {
        vm.createSelectFork(vm.envOr("BSC_TESTNET_RPC", string("https://bsc-testnet-rpc.publicnode.com")));
        IERC20 token = IERC20(TAX_TOKEN);
        address holder = address(uint160(uint256(keccak256("holder"))));
        address puller = address(uint160(uint256(keccak256("puller"))));
        uint256 amount = 1_000e18;
        deal(TAX_TOKEN, holder, amount, true);

        vm.prank(holder);
        token.approve(puller, amount);
        vm.prank(puller);
        token.transferFrom(holder, puller, amount);

        assertEq(token.balanceOf(puller), amount, "transferFrom was taxed; the ledger would over-credit");
    }
}
