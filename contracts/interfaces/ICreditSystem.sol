// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface ICreditSystem {
    function userCredits(address _user) external view returns (uint256);
    function assignCredits(address _user, uint256 _amount) external;
    function reduceCredits(address _user, uint256 _amount) external;
    function reduceCreditsForDefault(address _defaulter, address _recipient, uint256 _amount, address _validator) external;
    function stakeToken(address _token, uint256 _amount) external;
    function unstakeToken(address _token, uint256 _amount) external;
    function registerPurse(address _purse) external;
    function setPurseStatus(address _purse, bool _status) external;
    function setUserValidator(address _user, address _validator) external;
    function transferCredits(address _from, address _to, uint256 _amount) external;
    
    // New functions for purse credit management
    function commitCreditsToPurse(address _user, address _purse, uint256 _amount, address _validator) external;
    function handleUserDefault(address _user, address _purse, uint256 _amount, address _recipient) external;
    function releasePurseCredits(address _user, address _purse) external;
    function getUserPurseCredit(address _user, address _purse) external view returns (uint256 amount, address validator, bool active);
    function getValidatorDefaulterHistory(address _validator, address _user) external view returns (uint256);
    function getUserStakedTokens(address _user) external view returns (address[] memory tokens, uint256[] memory amounts);
    function getUserTokenStake(address _user, address _token) external view returns (uint256);
    function getUserTokenStakeInfo(address _user, address _token) external view returns (
        uint256 amount,
        uint256 timestamp,
        uint256 creditsIssued,
        address token
    );
} 