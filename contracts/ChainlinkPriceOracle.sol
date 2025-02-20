// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import '@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol';
import './interfaces/IPriceOracle.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import './access/Roles.sol';

error InvalidPriceFeed();
error StalePrice();
error PriceNotSupported();

contract ChainlinkPriceOracle is IPriceOracle, AccessControl {
    mapping(address => address) public priceFeeds;
    mapping(address => uint256) public lastUpdateTimes;

    uint256 public constant PRICE_STALENESS_THRESHOLD = 24 hours; // 24 hours in seconds

    event FeedUpdated(address token, address feed);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Roles.ADMIN_ROLE, msg.sender);
    }

    function setFeed(
        address token,
        address feed
    ) external onlyRole(Roles.ADMIN_ROLE) {
        priceFeeds[token] = feed;
        emit FeedUpdated(token, feed);
    }

    function getPrice(address token) external view override returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            priceFeeds[token]
        );
        if (address(priceFeed) == address(0)) revert PriceNotSupported();

        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        if (price <= 0) revert InvalidPriceFeed();
        if (block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD)
            revert StalePrice();

        return uint256(price);
    }

    function isPriceSupported(
        address token
    ) external view override returns (bool) {
        return priceFeeds[token] != address(0);
    }

    function getLastUpdateTime(
        address token
    ) external view override returns (uint256) {
        address feed = priceFeeds[token];
        if (feed == address(0)) return 0;

        (, , , uint256 timeStamp, ) = AggregatorV3Interface(feed)
            .latestRoundData();
        return timeStamp;
    }
}
