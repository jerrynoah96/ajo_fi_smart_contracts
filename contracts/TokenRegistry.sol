// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./access/Roles.sol";

/**
 * @title TokenRegistry
 * @notice Central registry for managing whitelisted tokens in the protocol
 * @dev This contract maintains a list of approved tokens that can be used across the protocol
 */
contract TokenRegistry is AccessControl {
    // Custom errors
    error ZeroAddress();
    error ArrayLengthMismatch();
    
    // Mapping from token address to whether it is whitelisted
    mapping(address => bool) public whitelistedTokens;
    
    // Array to keep track of all whitelisted tokens
    address[] public tokenList;
    
    // Events
    event TokenWhitelisted(address indexed token, bool status);
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Roles.ADMIN_ROLE, msg.sender);
    }
    
    /**
     * @notice Set the whitelist status of a token
     * @param _token The token address
     * @param _status Whether the token should be whitelisted
     */
    function setTokenWhitelist(address _token, bool _status) external onlyRole(Roles.ADMIN_ROLE) {
        if (_token == address(0)) revert ZeroAddress();
        
        // Update only if status is changing
        if (whitelistedTokens[_token] != _status) {
            whitelistedTokens[_token] = _status;
            
            // Add to array if whitelisting
            if (_status && !_isInList(_token)) {
                tokenList.push(_token);
            }
            
            emit TokenWhitelisted(_token, _status);
        }
    }
    
    /**
     * @notice Batch whitelist multiple tokens
     * @param _tokens Array of token addresses
     * @param _statuses Array of whitelist statuses
     */
    function batchSetTokenWhitelist(
        address[] calldata _tokens, 
        bool[] calldata _statuses
    ) external onlyRole(Roles.ADMIN_ROLE) {
        if (_tokens.length != _statuses.length) revert ArrayLengthMismatch();
        
        for (uint i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            bool status = _statuses[i];
            
            if (token == address(0)) revert ZeroAddress();
            
            // Update only if status is changing
            if (whitelistedTokens[token] != status) {
                whitelistedTokens[token] = status;
                
                // Add to array if whitelisting
                if (status && !_isInList(token)) {
                    tokenList.push(token);
                }
                
                emit TokenWhitelisted(token, status);
            }
        }
    }
    
    /**
     * @notice Check if a token is whitelisted
     * @param _token The token address to check
     * @return Whether the token is whitelisted
     */
    function isTokenWhitelisted(address _token) external view returns (bool) {
        return whitelistedTokens[_token];
    }
    
    /**
     * @notice Get all whitelisted tokens
     * @return Array of all whitelisted token addresses
     */
    function getAllWhitelistedTokens() external view returns (address[] memory) {
        // Create a new array to hold only active whitelisted tokens
        uint256 activeCount = 0;
        
        // First count active tokens
        for (uint256 i = 0; i < tokenList.length; i++) {
            if (whitelistedTokens[tokenList[i]]) {
                activeCount++;
            }
        }
        
        // Create result array of the right size
        address[] memory result = new address[](activeCount);
        uint256 resultIndex = 0;
        
        // Fill result array
        for (uint256 i = 0; i < tokenList.length; i++) {
            if (whitelistedTokens[tokenList[i]]) {
                result[resultIndex] = tokenList[i];
                resultIndex++;
            }
        }
        
        return result;
    }
    
    /**
     * @notice Check if a token is in the tokenList array
     * @param _token The token address to check
     * @return Whether the token is in the list
     */
    function _isInList(address _token) internal view returns (bool) {
        for (uint256 i = 0; i < tokenList.length; i++) {
            if (tokenList[i] == _token) {
                return true;
            }
        }
        return false;
    }
} 