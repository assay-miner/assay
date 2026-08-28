// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "../src/flap/IPortal.sol";

/// @notice Pins the parameters a launch is made with.
///
/// @dev These decide how much money the protocol ever has and for how long, and a token launch
///      cannot be undone — the rate is fixed at creation for the duration set here. Until now
///      nothing tested them: the rate lived as a literal in a deploy script, and changing it by
///      accident would have shown up first as a live token collecting the wrong amount forever.
contract LaunchParamsTest is Test {
    Deploy internal deploy;

    function setUp() public {
        deploy = new Deploy();
    }

    function _params() internal view returns (IVaultPortalTypes.NewTokenV6WithVaultParams memory) {
        return deploy.launchParams(address(0xF), bytes32(uint256(1)), "Assay", "ASSAY");
    }

    /// @notice Two percent each way, the owner's decision, in basis points.
    function test_TheTaxIsTwoPercentBothWays() public view {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params();
        assertEq(p.buyTaxRate, 200, "buy tax drifted from 2%");
        assertEq(p.sellTaxRate, 200, "sell tax drifted from 2%");
    }

    /// @notice All of it reaches the vault. `mktBps` is the share routed there, in basis points.
    function test_EveryBasisPointOfTaxReachesTheVault() public view {
        assertEq(_params().mktBps, 10_000, "some of the tax is being routed elsewhere");
    }

    /// @notice A year of collection, and the anti-farming window Flap applies at launch.
    function test_TheCollectionWindowIsAYear() public view {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params();
        assertEq(p.taxDuration, 365 days, "tax duration drifted");
        assertEq(p.antiFarmerDuration, 30 days, "anti-farmer window drifted");
    }

    /// @notice The three settings a taxed-V3 launch will not accept anything else for.
    /// @dev Each was found by asking the portal, not by reading its interface: FOUR_FIFTHS is the
    ///      only threshold it takes, native BNB needs V2_MIGRATOR, and the token version has to
    ///      be the taxed one or the tax never reaches a vault at all.
    function test_ThePortalOnlyAcceptsTheseThree() public view {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params();
        assertEq(uint8(p.dexThresh), uint8(IPortalCommonTypes.DexThreshType.FOUR_FIFTHS));
        assertEq(uint8(p.migratorType), uint8(IPortalTypes.MigratorType.V2_MIGRATOR));
        assertEq(uint8(p.tokenVersion), uint8(IPortalTypes.TokenVersion.TOKEN_TAXED_V3));
        assertEq(p.quoteToken, address(0), "quote token is no longer native BNB");
    }

    /// @notice No dev buy at launch. Nothing is bought for us out of the launch itself.
    function test_NoDevBuy() public view {
        assertEq(_params().quoteAmt, 0, "a dev buy appeared in the launch parameters");
    }
}
