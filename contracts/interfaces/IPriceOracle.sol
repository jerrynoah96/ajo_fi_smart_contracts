// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IPriceOracle {
    /// @notice Get the price of a token in USD (with 18 decimals)
    /// @param token The token address to get the price for
    /// @return price The USD price of the token (1 USD = 1e18)
    function getPrice(address token) external view returns (uint256);

    /// @notice Check if a price feed is supported
    /// @param token The token address to check
    function isPriceSupported(address token) external view returns (bool);

    /// @notice Get the last update timestamp for a price feed
    /// @param token The token address to check
    function getLastUpdateTime(address token) external view returns (uint256);
}
