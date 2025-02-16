// contracts/interfaces/IValidator.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IValidator {
    struct ValidatorData {
        address owner;
        uint256 feePercentage;
        address stakedToken;
        uint256 stakedAmount;
        bool isActive;
    }

    function data() external view returns (ValidatorData memory);
    function isUserValidated(address _user) external view returns (bool);
    function getStakedToken() external view returns (address);
    function handleDefaulterPenalty(
        address defaulter,
        address recipient,
        uint256 amount
    ) external;
    function validateUser(address user) external;
    function removeUserValidation(address user) external;
    function withdrawStake(uint256 amount, address user) external;
    function refundStake(uint256 amount, address user) external;
}
