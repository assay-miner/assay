// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IPancakeRouter02} from "./interfaces/IPancakeRouter02.sol";

/// @title PriceGuard
/// @notice Prices a BNB→BTCB conversion and says how large one may be.
///
/// @dev Split out of the vault for a reason that is entirely about bytes and worth stating rather
///      than dressing up: the factory embeds the vault's creation code and lives under EIP-170, and
///      the binary search below is the largest piece of the vault that nothing else depends on
///      being in the same contract. It is pure arithmetic over a router the vault already trusts.
///
///      It holds no funds, has no owner and no privileged caller. Its address is fixed in the
///      vault at construction, because a caller-supplied pricing contract is a caller-supplied
///      answer to "how much may I convert" — the venue must not be an argument.
///
///      Deployed behind a beacon, so the three addresses below are storage rather than immutable:
///      an implementation's immutables live in its own code, and the proxy that delegatecalls into
///      it would read them from a contract it does not have. Nothing else about the contract moves.
///      The upgrade authority is the beacon's, held by the Flap Guardian; there is deliberately no
///      owner and no upgrade entry point here — the sentence above still holds literally.
contract PriceGuard is Initializable {
    IERC20 public reward;
    IPancakeRouter02 public router;
    address public wrappedNative;

    /// @notice The probe used to read a marginal price uncontaminated by the size being priced.
    uint256 public constant SPOT_PROBE = 0.01 ether;
    /// @notice The most a conversion may move the pool against itself.
    uint256 public constant MAX_SLIPPAGE_BPS = 300;

    /// @dev Fifty reserved slots so a later version can add state at a fixed place instead of at
    ///      whatever offset the contract happens to end at. Layout is permanent the moment a
    ///      beacon points here — the values live in the proxy, not in the code being replaced —
    ///      so a future version must append into this gap, must not reorder the three above, and
    ///      must not drop `Initializable` from the front of the bases. As built: OZ 4.9 puts
    ///      `_initialized`/`_initializing` in the first two bytes of slot 0, `reward` packs in
    ///      behind them at offset 2, `router` is slot 1, `wrappedNative` slot 2, and this gap is
    ///      slots 3 through 52.
    uint256[50] private __gap;


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Picks the venue from the chain it is being deployed on, once.
    ///
    /// @dev Was the constructor, verbatim — same chain ids, same addresses, same refusal. Two
    ///      things it used to get from being a constructor it now gets from `initializer`:
    ///      construction ran exactly once by definition, and this modifier is what replaces that
    ///      guarantee, so the venue cannot be re-pointed at a second call. And
    ///      `_disableInitializers` above burns it on the implementation itself, which is why the
    ///      implementation reads as a guard over a zero router, and why the address handed to a
    ///      vault must be the proxy and never the implementation.
    ///
    ///      No arguments, deliberately. The addresses are not the deployer's to choose: a pricing
    ///      contract initialised with a router someone passed in is a caller-supplied answer to the
    ///      question this contract exists to answer, which is the same objection the vault's own
    ///      note above makes about the venue. `block.chainid` is the same under delegatecall from
    ///      the proxy as it was under construction, so the answer is unchanged.
    function initialize() external initializer {
        uint256 chainId = block.chainid;
        address rewardToken;
        address routerAddr;
        if (chainId == 56) {
            rewardToken = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c; // BTCB
            routerAddr = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // PancakeSwap V2
        } else if (chainId == 97) {
            rewardToken = 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8;
            routerAddr = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
        }
        require(routerAddr != address(0), unicode"Bad chain / 链不支持");
        reward = IERC20(rewardToken);
        router = IPancakeRouter02(routerAddr);
        wrappedNative = IPancakeRouter02(routerAddr).WETH();
    }

    /// @notice What `bnbAmount` buys right now, through the pool the vault will actually use.
    function quote(uint256 bnbAmount) public view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = wrappedNative;
        path[1] = address(reward);
        uint256[] memory amounts = router.getAmountsOut(bnbAmount, path);
        return amounts[amounts.length - 1];
    }

    /// @notice The marginal price, read with a probe small enough not to move it.
    function spotUnitPrice() public view returns (uint256) {
        return (quote(SPOT_PROBE) * 1e18) / SPOT_PROBE;
    }

    /// @notice How far `bnbAmount` falls short of the marginal price, in basis points.
    function impactBps(uint256 bnbAmount) public view returns (uint256) {
        uint256 ideal = (spotUnitPrice() * bnbAmount) / 1e18;
        if (ideal == 0) return 10_000;
        uint256 actual = quote(bnbAmount);
        if (actual >= ideal) return 0;
        return ((ideal - actual) * 10_000) / ideal;
    }

    /// @notice The largest conversion that stays inside the impact bound.
    /// @dev A search rather than a formula because the pool's reserves are the only honest source,
    ///      and a closed form derived from them drifts the moment either side moves.
    function maxConvertible() public view returns (uint256) {
        uint256 lo;
        uint256 hi = 1_000_000 ether;
        if (impactBps(hi) <= MAX_SLIPPAGE_BPS) return hi;
        for (uint256 i; i < 64; ++i) {
            uint256 mid = (lo + hi + 1) / 2;
            if (mid == lo) break;
            if (impactBps(mid) <= MAX_SLIPPAGE_BPS) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }
}
