// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The Guardian address fixtures build their beacons under.
///
/// @dev `Stack.guardian()` resolves from `block.chainid` and returns `address(0)` on a chain Flap is
///      not on — which is correct for a deployment and useless for a test, because most of this
///      suite runs on the local chain and `UpgradeableBeacon` rejects a zero owner.
///
///      So fixtures pass this instead. It is the REAL testnet Guardian rather than a made-up
///      address, so a test that asserts "only the Guardian may upgrade" is asserting it about the
///      same account that will hold the key in production, not about a placeholder that happens to
///      differ from every other address in the fixture.
library Guardians {
    address internal constant TESTNET = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    address internal constant MAINNET = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
}
