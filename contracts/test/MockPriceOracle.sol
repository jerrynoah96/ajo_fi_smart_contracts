// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../interfaces/IPriceOracle.sol";

contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public prices;
    mapping(address => uint256) public lastUpdateTimes;
    mapping(address => bool) public supportedPrices;
    
    // Default price is 1 USD with 18 decimals
    uint256 public constant DEFAULT_PRICE = 1e18;
    
    function getPrice(address token) external view override returns (uint256) {
        if (prices[token] == 0) {
            return DEFAULT_PRICE; // Default price if not set
        }
        return prices[token];
    }
    
    function isPriceSupported(address token) external view override returns (bool) {
        // By default all tokens are supported in the mock
        return supportedPrices[token] || prices[token] > 0;
    }
    
    function getLastUpdateTime(address token) external view override returns (uint256) {
        return lastUpdateTimes[token] > 0 ? lastUpdateTimes[token] : block.timestamp;
    }
    
    function setPrice(address token, uint256 price) external {
        prices[token] = price;
        lastUpdateTimes[token] = block.timestamp;
        supportedPrices[token] = true;
    }
    
    function setSupportedPrice(address token, bool isSupported) external {
        supportedPrices[token] = isSupported;
    }
} 