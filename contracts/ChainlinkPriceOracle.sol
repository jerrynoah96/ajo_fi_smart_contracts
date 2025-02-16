// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./interfaces/IPriceOracle.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./access/Roles.sol";

contract ChainlinkPriceOracle is IPriceOracle, AccessControl {
    mapping(address => address) public priceFeeds;
    mapping(address => uint256) public lastUpdateTimes;

    event FeedUpdated(address token, address feed);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Roles.ADMIN_ROLE, msg.sender);
    }

    function setFeed(address token, address feed) external onlyRole(Roles.ADMIN_ROLE) {
        priceFeeds[token] = feed;
        emit FeedUpdated(token, feed);
    }

    function getPrice(address token) external view override returns (uint256) {
        address feed = priceFeeds[token];
        require(feed != address(0), "Feed not found");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);
        (
            uint80 roundID,
            int256 price,
            uint256 startedAt,
            uint256 timeStamp,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        require(timeStamp > 0, "Round not complete");
        require(price > 0, "Invalid price");

        // Convert to 18 decimals
        uint8 decimals = priceFeed.decimals();
        return uint256(price) * 10**(18 - decimals);
    }

    function isPriceSupported(address token) external view override returns (bool) {
        return priceFeeds[token] != address(0);
    }

    function getLastUpdateTime(address token) external view override returns (uint256) {
        address feed = priceFeeds[token];
        if (feed == address(0)) return 0;
        
        (, , , uint256 timeStamp, ) = AggregatorV3Interface(feed).latestRoundData();
        return timeStamp;
    }
} 