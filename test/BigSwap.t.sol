// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {AssayFlapVault} from "../src/AssayFlapVault.sol";

/// @notice Does a large accumulated balance actually fail to convert?
/// @dev A reviewer read the 3% bound as a cap on price impact and concluded that converting a big
///      pile in one shot would structurally revert. The bound is measured against
///      `quote(bnbAmount)`, and `getAmountsOut` already prices the impact of that exact size — so
///      the question is whether the floor is a cap on impact or a tolerance for the pool moving
///      between scheduling and execution. Those are very different findings, so measure it.
contract BigSwapTest is BaseTest {
    AssayFlapVault internal flap;
    address internal guardian;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("bsc"));
        super.setUp();
        flap = new AssayFlapVault(tournament, address(token), CURATOR);
        guardian = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    }

    function _convert(uint256 bnb) internal returns (uint256 out) {
        vm.deal(address(flap), bnb);
        uint256 floor_ = (flap.quote(bnb) * 9_700) / 10_000;
        vm.prank(guardian);
        return flap.endow(taskId, bnb, floor_);
    }

    /// @notice Sizes the pool can absorb go through; sizes that would eat the tax do not.
    function test_TheImpactCapBindsWhereTheMeasurementSaysItShould() public {
        uint256 cap = flap.maxConvertible();
        emit log_named_uint("maxConvertible, bnb", cap / 1e18);
        assertGt(cap, 1 ether, "nothing at all can be converted");
        assertLt(cap, 500 ether, "the cap is nowhere near the measured 18% point");

        // Just inside: accepted.
        uint256 snap = vm.snapshotState();
        assertGt(_convert(cap), 0, "a size at the published cap was refused");
        vm.revertToState(snap);

        // Just outside: refused, and the message names where to look.
        uint256 over = cap + (cap / 10);
        vm.deal(address(flap), over);
        uint256 floor_ = (flap.quote(over) * 9_700) / 10_000;
        vm.prank(guardian);
        vm.expectRevert(bytes(unicode"Too big; see maxConvertible() / 金额过大,见 maxConvertible()"));
        flap.endow(taskId, over, floor_);
    }

    /// @notice The case that used to pass: two thousand BNB, half the value gone, no objection.
    function test_ARuinousConversionIsNowRefused() public {
        uint256 bnb = 2000 ether;
        vm.deal(address(flap), bnb);
        uint256 floor_ = (flap.quote(bnb) * 9_700) / 10_000;

        vm.prank(guardian);
        vm.expectRevert();
        flap.endow(taskId, bnb, floor_);
    }

    /// @notice The published number has to be the real boundary, not an estimate near it.
    function test_TheCapIsExact() public {
        uint256 cap = flap.maxConvertible();
        uint256 unit = flap.spotUnitPrice();
        uint256 atCap = (10_000 * ((unit * cap) / 1e18 - flap.quote(cap))) / ((unit * cap) / 1e18);
        uint256 justOver = (10_000 * ((unit * (cap + 1e17)) / 1e18 - flap.quote(cap + 1e17)))
            / ((unit * (cap + 1e17)) / 1e18);
        emit log_named_uint("impact at the cap, bps", atCap);
        emit log_named_uint("impact just past it, bps", justOver);
        assertLe(atCap, 300, "the cap itself exceeds the tolerance");
        assertGt(justOver, 300, "the cap is set below the real boundary");
    }

    /// @notice What each size actually costs, and where the cap now falls among them.
    ///
    /// @dev These numbers are why the cap exists. Measured independently — a snapshot per size,
    ///      because run in sequence the earlier conversions drain the pool and the later figures
    ///      measure that drainage rather than the size being tested. Every one of them used to
    ///      pass.
    function test_WhatEachSizeCostsAndWhereTheCapFalls() public {
        uint256 cap = flap.maxConvertible();
        uint256 unit = flap.spotUnitPrice();
        uint256[7] memory sizes = [uint256(1), 10, 60, 100, 500, 1000, 2000];

        for (uint256 i; i < sizes.length; ++i) {
            uint256 bnb = sizes[i] * 1e18;
            uint256 ideal = (unit * bnb) / 1e18;
            uint256 lost = ((ideal - flap.quote(bnb)) * 10_000) / ideal;
            emit log_named_uint(string.concat("bnb=", vm.toString(sizes[i]), " lost bps"), lost);

            uint256 snap = vm.snapshotState();
            vm.deal(address(flap), bnb);
            uint256 floor_ = (flap.quote(bnb) * 9_700) / 10_000;
            vm.prank(guardian);
            if (bnb <= cap) {
                assertGt(flap.endow(taskId, bnb, floor_), 0, "a size under the cap was refused");
            } else {
                vm.expectRevert(bytes(unicode"Too big; see maxConvertible() / 金额过大,见 maxConvertible()"));
                flap.endow(taskId, bnb, floor_);
            }
            vm.revertToState(snap);
        }
    }

    /// @notice The bound is a tolerance for movement, not a cap on impact — this is what it stops.
    function test_TheFloorStopsAPoolThatMovedAgainstYou() public {
        uint256 bnb = 100e18;
        vm.deal(address(flap), bnb);
        uint256 floor_ = flap.quote(bnb);   // demand the full quote, no tolerance at all

        // Ask for more than the pool will give: 1% above what it quotes right now.
        vm.prank(guardian);
        vm.expectRevert();
        flap.endow(taskId, bnb, (floor_ * 101) / 100);
    }
}
