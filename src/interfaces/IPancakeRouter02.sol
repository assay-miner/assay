// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The two router calls this protocol needs, and nothing else.
/// @dev Declared here rather than vendored: a full router interface would bring in a dozen
///      functions nobody calls, and every one of them is a signature that can drift unnoticed.
interface IPancakeRouter02 {
    /// @notice Swaps an exact amount of native BNB for as many output tokens as possible.
    /// @return amounts Input and output amounts along `path`; the last element is what arrived.
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    /// @notice Quotes `swapExactETHForTokens` without executing it.
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    /// @notice The wrapped native token this router routes through.
    function WETH() external view returns (address);
}
