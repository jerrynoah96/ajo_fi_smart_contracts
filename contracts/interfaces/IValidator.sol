// contracts/interfaces/IValidator.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

interface IValidator {
    struct ValidatorData {
        address owner;
        uint256 feePercentage;
        address stakedToken;
    }

    struct ValidationData {
        bool isValidated;
        uint256 creditAmount;
    }

    function data() external view returns (ValidatorData memory);
    function validateUser(address _user, uint256 _amount) external;
    function invalidateUser(address _user) external;
    function handleDefaulterPenalty(address _defaulter, address _recipient, uint256 _amount) external;
    function isUserValidated(address _user) external view returns (bool);
    function getValidatorData() external view returns (ValidatorData memory);
    function withdrawStake(uint256 amount) external;
    function addStake(uint256 amount) external;
    function validatedUsers(address _user) external view returns (ValidationData memory);
    
    // Events
    event UserValidated(address indexed user);
    event UserInvalidated(address indexed user);
    event CreditsAssignedToUser(address indexed user, uint256 amount);
    event CreditsWithdrawnFromUser(address indexed user, uint256 amount);
    event StakeWithdrawn(uint256 amount);
    event StakeAdded(uint256 amount);
}
