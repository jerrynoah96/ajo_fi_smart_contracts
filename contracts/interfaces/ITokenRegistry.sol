// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface ITokenRegistry {
    function isTokenWhitelisted(address _token) external view returns (bool);
    function setTokenWhitelist(address _token, bool _status) external;
    function getAllWhitelistedTokens() external view returns (address[] memory);
    
    event TokenWhitelisted(address indexed token, bool status);
} 