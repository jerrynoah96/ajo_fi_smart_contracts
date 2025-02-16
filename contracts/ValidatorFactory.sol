// contracts/ValidatorFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/ICreditSystem.sol";
import "./interfaces/IValidator.sol";
import "./Validator.sol";
import "./access/Roles.sol";

contract ValidatorFactory is AccessControl, ReentrancyGuard {
    struct ValidatorConfig {
        uint256 minStakeAmount;      // Minimum amount validator must stake
        uint256 maxFeePercentage;    // Maximum fee validator can charge (in basis points)
    }

    ICreditSystem public immutable creditSystem;
    
    ValidatorConfig public config;
    mapping(address => address) public validatorContracts; // validator address => validator contract
    address[] public validatorList;

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

    constructor(
        address _creditSystem,
        uint256 _minStakeAmount,
        uint256 _maxFeePercentage
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Roles.ADMIN_ROLE, msg.sender);
        
        creditSystem = ICreditSystem(_creditSystem);
        
        config = ValidatorConfig({
            minStakeAmount: _minStakeAmount,
            maxFeePercentage: _maxFeePercentage
        });
    }

    function createValidator(uint256 _feePercentage, address _tokenToStake) external nonReentrant {
        require(validatorContracts[msg.sender] == address(0), "Already registered");
        require(_feePercentage <= config.maxFeePercentage, "Fee too high");
        require(
            IERC20(_tokenToStake).balanceOf(msg.sender) >= config.minStakeAmount,
            "Insufficient stake"
        );

        // Deploy new validator contract
        Validator validator = new Validator(
            config.minStakeAmount,
            _feePercentage,
            _tokenToStake,
            msg.sender,
            address(creditSystem)
        );

        // Transfer stake
        IERC20(_tokenToStake).transferFrom(msg.sender, address(validator), config.minStakeAmount);

        validatorContracts[msg.sender] = address(validator);
        validatorList.push(msg.sender);

        emit ValidatorCreated(
            msg.sender,
            address(validator),
            config.minStakeAmount,
            _feePercentage
        );
    }

    function getValidatorContract(address _validator) external view returns (address) {
        return validatorContracts[_validator];
    }

    function getActiveValidators() external view returns (address[] memory) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < validatorList.length; i++) {
            address validatorContract = validatorContracts[validatorList[i]];
            if (validatorContract != address(0)) {
                IValidator validator = IValidator(validatorContract);
                if (validator.data().isActive) {
                    activeCount++;
                }
            }
        }

        address[] memory activeValidators = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < validatorList.length; i++) {
            address validatorContract = validatorContracts[validatorList[i]];
            if (validatorContract != address(0)) {
                IValidator validator = IValidator(validatorContract);
                if (validator.data().isActive) {
                    activeValidators[index] = validatorList[i];
                    index++;
                }
            }
        }

        return activeValidators;
    }

    function updateConfig(
        uint256 _minStakeAmount,
        uint256 _maxFeePercentage
    ) external onlyRole(Roles.ADMIN_ROLE) {
        config = ValidatorConfig({
            minStakeAmount: _minStakeAmount,
            maxFeePercentage: _maxFeePercentage
        });

        emit ValidatorConfigUpdated(
            _minStakeAmount,
            _maxFeePercentage
        );
    }
}