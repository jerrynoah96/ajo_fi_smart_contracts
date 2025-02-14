// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface ICreditSystem {
    function userCredits(address user) external view returns (uint256);
    function reduceCredits(address user, uint256 amount) external;
    function assignCredits(address user, uint256 amount) external;
    function registerPurse(address purse) external;
    function grantValidatorRole(address validator) external;
    function getValidatorFactory() external view returns (address);
    
    // Add these new functions for validator-user relationship
    function getUserValidator(address user) external view returns (address);
    function setUserValidator(address user, address validator) external;
    function removeUserValidator(address user) external;

    function reduceCreditsForDefault(
        address _user,
        address _recipient,
        uint256 _amount,
        address _validator
    ) external;
} 