// contracts/interfaces/IValidatorFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IValidatorFactory {
    struct ValidatorConfig {
        uint256 minStakeAmount;
        uint256 maxFeePercentage;
    }

    event ValidatorCreated(
        address indexed validator,
        address indexed validatorContract,
        uint256 stakedAmount,
        uint256 feePercentage
    );
    
    event ValidatorConfigUpdated(
        uint256 minStakeAmount,
        uint256 maxFeePercentage
    );

    function getValidatorContract(address validator) external view returns (address);
    function createValidator(uint256 feePercentage, address tokenToStake) external;
    function getActiveValidators() external view returns (address[] memory);
    function config() external view returns (ValidatorConfig memory);
}