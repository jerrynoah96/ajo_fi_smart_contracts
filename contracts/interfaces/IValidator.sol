// contracts/interfaces/IValidator.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IValidator {
    struct ValidatorData {
        address owner;
        uint256 feePercentage;
        address stakedToken;
    }

    function data() external view returns (ValidatorData memory);
    function validateUser(address user, uint256 creditAmount) external;
    function invalidateUser(address user, uint256 creditAmount) external;
    function isUserValidated(address user) external view returns (bool);
    function handleDefaulterPenalty(address defaulter, address recipient, uint256 amount) external;
    function getValidatorData() external view returns (ValidatorData memory);
    function withdrawStake(uint256 amount) external;
    function addStake(uint256 amount) external;
    
    // Events
    event UserValidated(address indexed user);
    event UserInvalidated(address indexed user);
    event StakeReduced(uint256 amount, address indexed defaulter, string reason);
    event CreditsAssignedToUser(address indexed user, uint256 amount);
    event CreditsWithdrawnFromUser(address indexed user, uint256 amount);
    event StakeWithdrawn(uint256 amount);
    event StakeAdded(uint256 amount);
}
