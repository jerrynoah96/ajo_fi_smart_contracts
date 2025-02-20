// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import '../interfaces/IPriceOracle.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '../access/Roles.sol';

contract MockPriceOracle is IPriceOracle, AccessControl {
    mapping(address => uint256) private prices;
    mapping(address => uint256) private lastUpdateTimes;
    mapping(address => bool) private supportedTokens;

    error PriceNotSupported();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Roles.ADMIN_ROLE, msg.sender);
        _grantRole(Roles.PRICE_FEEDER_ROLE, msg.sender);
    }

    function setPrice(
        address token,
        uint256 price
    ) external onlyRole(Roles.PRICE_FEEDER_ROLE) {
        prices[token] = price;
        lastUpdateTimes[token] = block.timestamp;
        supportedTokens[token] = true;
    }

    function getPrice(address token) external view override returns (uint256) {
        if (!supportedTokens[token]) revert PriceNotSupported();
        return prices[token];
    }

    function isPriceSupported(
        address token
    ) external view override returns (bool) {
        return supportedTokens[token];
    }

    function getLastUpdateTime(
        address token
    ) external view override returns (uint256) {
        return lastUpdateTimes[token];
    }

    function setLastUpdateTime(
        address token,
        uint256 timestamp
    ) external onlyRole(Roles.PRICE_FEEDER_ROLE) {
        lastUpdateTimes[token] = timestamp;
    }

    function setSupportedStatus(
        address token,
        bool status
    ) external onlyRole(Roles.PRICE_FEEDER_ROLE) {
        supportedTokens[token] = status;
    }

    function authorizeCaller(
        address caller
    ) external onlyRole(Roles.ADMIN_ROLE) {
        _grantRole(Roles.PRICE_FEEDER_ROLE, caller);
    }
}
